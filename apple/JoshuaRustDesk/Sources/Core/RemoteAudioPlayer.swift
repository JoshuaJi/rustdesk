import AudioToolbox
import AVFoundation
import Foundation

/// Remote desktop audio player.
///
/// Pipeline: Rust Opus decode → interleaved f32 PCM callback → AudioQueue.
/// AudioQueue is used instead of AVAudioEngine for simpler, more reliable
/// streaming of fixed-rate PCM on iOS.
final class RemoteAudioPlayer {
    static let shared = RemoteAudioPlayer()

    private let lock = NSLock()
    private var ring: [Float] = []
    private let maxRingSamples = 48_000 * 2 * 3 // ~3s stereo @ 48k

    private var sampleRate: Double = 0
    private var channels: UInt32 = 0
    private var bytesPerFrame: UInt32 = 0

    private var queue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef] = []
    private let bufferCount = 4
    private var bufferFrames: UInt32 = 1024
    private var running = false
    private var localMuted = false
    private var startedLogged = false

    private(set) var framesReceived: UInt64 = 0
    private(set) var callbacksReceived: UInt64 = 0

    private init() {}

    // MARK: - Lifecycle

    func start() {
        configureSession()
        registerRustCallback()
        NSLog("RemoteAudioPlayer: callback registered")
    }

    func stop() {
        clearRustCallback()
        stopQueue()
        lock.lock()
        ring.removeAll(keepingCapacity: true)
        framesReceived = 0
        callbacksReceived = 0
        sampleRate = 0
        channels = 0
        startedLogged = false
        lock.unlock()
    }

    func setLocalMuted(_ muted: Bool) {
        localMuted = muted
        if muted {
            lock.lock()
            ring.removeAll(keepingCapacity: true)
            lock.unlock()
        }
    }

    // MARK: - PCM from Rust (audio thread)

    fileprivate func enqueue(samples: UnsafePointer<Float>, count: Int, rate: UInt32, ch: UInt16) {
        guard count > 0, ch > 0, rate >= 8000 else { return }

        lock.lock()
        callbacksReceived &+= 1
        let cbN = callbacksReceived
        framesReceived &+= UInt64(count / max(1, Int(ch)))
        let rateD = Double(rate)
        let chU = UInt32(ch)
        let formatChanged = sampleRate < 1
            || abs(rateD - sampleRate) > 1
            || chU != channels

        if formatChanged {
            sampleRate = rateD
            channels = chU
            bytesPerFrame = chU * UInt32(MemoryLayout<Float>.size)
            // ~10–20 ms buffers
            bufferFrames = max(256, UInt32(rate) / 50)
        }

        if !localMuted {
            let buf = UnsafeBufferPointer(start: samples, count: count)
            ring.append(contentsOf: buf)
            if ring.count > maxRingSamples {
                ring.removeFirst(ring.count - maxRingSamples)
            }
        }
        let needStart = !running || formatChanged
        let ringCount = ring.count
        lock.unlock()

        if cbN == 1 || cbN % 200 == 0 {
            NSLog("RemoteAudioPlayer: pcm#\(cbN) floats=\(count) rate=\(rate) ch=\(ch) ring=\(ringCount) running=\(running)")
        }

        if needStart {
            let r = rateD
            let c = chU
            DispatchQueue.main.async { [weak self] in
                self?.startQueue(rate: r, channels: c)
            }
        }
    }

    // MARK: - AVAudioSession

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            do {
                try session.setCategory(.playback)
                try session.setActive(true)
            } catch {
                NSLog("RemoteAudioPlayer: session error \(error)")
            }
        }
    }

    // MARK: - AudioQueue

    private func startQueue(rate: Double, channels ch: UInt32) {
        precondition(Thread.isMainThread)
        stopQueue()
        configureSession()

        guard rate >= 8000, ch >= 1, ch <= 8 else { return }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: ch * UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: ch * UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: ch,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var q: AudioQueueRef?
        // Pass self as user data for the C callback.
        let user = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioQueueNewOutput(
            &asbd,
            audioQueueOutputCallback,
            user,
            nil, // internal thread
            nil,
            0,
            &q
        )
        guard status == noErr, let queue = q else {
            NSLog("RemoteAudioPlayer: AudioQueueNewOutput failed \(status)")
            return
        }

        self.queue = queue
        self.sampleRate = rate
        self.channels = ch
        self.bytesPerFrame = ch * UInt32(MemoryLayout<Float>.size)
        self.bufferFrames = max(256, UInt32(rate) / 50)

        let bufBytes = bufferFrames * bytesPerFrame
        buffers.removeAll()
        for _ in 0..<bufferCount {
            var buf: AudioQueueBufferRef?
            let s = AudioQueueAllocateBuffer(queue, bufBytes, &buf)
            if s == noErr, let buf {
                buffers.append(buf)
                // Prime with silence so the queue starts.
                memset(buf.pointee.mAudioData, 0, Int(bufBytes))
                buf.pointee.mAudioDataByteSize = bufBytes
                AudioQueueEnqueueBuffer(queue, buf, 0, nil)
            }
        }

        let startStatus = AudioQueueStart(queue, nil)
        if startStatus == noErr {
            running = true
            if !startedLogged {
                startedLogged = true
                NSLog("RemoteAudioPlayer: AudioQueue started \(Int(rate)) Hz × \(ch) ch")
            }
        } else {
            NSLog("RemoteAudioPlayer: AudioQueueStart failed \(startStatus)")
            AudioQueueDispose(queue, true)
            self.queue = nil
            running = false
        }
    }

    private func stopQueue() {
        if let queue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
        }
        queue = nil
        buffers.removeAll()
        running = false
    }

    /// Called from AudioQueue realtime thread — fill next buffer from ring.
    fileprivate func fill(buffer: AudioQueueBufferRef) {
        let frames = Int(bufferFrames)
        let ch = Int(max(1, channels))
        let floatsNeeded = frames * ch
        let byteCapacity = Int(buffer.pointee.mAudioDataBytesCapacity)
        let dst = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)

        lock.lock()
        let available = min(floatsNeeded, ring.count)
        if available > 0, !localMuted {
            for i in 0..<available {
                dst[i] = ring[i]
            }
            ring.removeFirst(available)
        }
        lock.unlock()

        // Pad with silence.
        if available < floatsNeeded {
            for i in available..<floatsNeeded {
                dst[i] = 0
            }
        }

        let bytes = min(floatsNeeded * MemoryLayout<Float>.size, byteCapacity)
        buffer.pointee.mAudioDataByteSize = UInt32(bytes)

        if let queue {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
    }

    // MARK: - Rust bridge

    private func registerRustCallback() {
        let user = Unmanaged.passUnretained(self).toOpaque()
        // Must use @convention(c) function pointer — see pcmTrampoline below.
        rd_set_pcm_callback(pcmTrampoline, user)
    }

    private func clearRustCallback() {
        rd_set_pcm_callback(nil, nil)
    }
}

// MARK: - C callbacks (must be @convention(c))

/// Rust → Swift PCM. `@convention(c)` is required for a valid C function pointer.
private let pcmTrampoline: @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<Float>?,
    Int,
    UInt32,
    UInt16
) -> Void = { user, samples, sampleCount, sampleRate, channels in
    guard let user, let samples, sampleCount > 0 else { return }
    let player = Unmanaged<RemoteAudioPlayer>.fromOpaque(user).takeUnretainedValue()
    player.enqueue(samples: samples, count: sampleCount, rate: sampleRate, ch: channels)
}

/// AudioQueue output callback (realtime thread).
private let audioQueueOutputCallback: AudioQueueOutputCallback = { user, queue, buffer in
    guard let user else { return }
    let player = Unmanaged<RemoteAudioPlayer>.fromOpaque(user).takeUnretainedValue()
    player.fill(buffer: buffer)
}
