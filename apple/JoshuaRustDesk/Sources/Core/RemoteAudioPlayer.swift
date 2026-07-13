import AudioToolbox
import AVFoundation
import Foundation

/// Remote desktop audio: Rust Opus → interleaved f32 → AudioQueue.
///
/// Always plays at **48 kHz stereo** (resampling on the way in) so the hardware
/// path is consistent. AUD in the HUD means PCM arrived; this file is responsible
/// for actually emitting it.
final class RemoteAudioPlayer {
    static let shared = RemoteAudioPlayer()

    // Output format (fixed for the queue lifetime).
    private let outRate: Double = 48_000
    private let outChannels: UInt32 = 2
    private var outBytesPerFrame: UInt32 { outChannels * 4 }

    private let lock = NSLock()
    /// Interleaved stereo f32 @ outRate.
    private var ring: [Float] = []
    private let maxRingSamples = 48_000 * 2 * 4 // 4s

    private var inRate: Double = 0
    private var inChannels: Int = 0

    private var queue: AudioQueueRef?
    private var aqBuffers: [AudioQueueBufferRef] = []
    private let bufferCount = 5
    private let bufferFrames: UInt32 = 960 // 20ms @ 48k
    private var running = false
    private var localMuted = false

    private(set) var framesReceived: UInt64 = 0
    private(set) var callbacksReceived: UInt64 = 0
    private var lastPeak: Float = 0

    private init() {}

    // MARK: - Public

    func start() {
        configureSession()
        registerRustCallback()
        // Pre-create 48k queue so the first packets aren't delayed/dropped.
        DispatchQueue.main.async { [weak self] in
            self?.ensureQueue()
        }
        NSLog("RemoteAudioPlayer: start")
    }

    func stop() {
        clearRustCallback()
        let stop = { [weak self] in self?.disposeQueue() }
        if Thread.isMainThread { stop() } else { DispatchQueue.main.sync(execute: stop) }
        lock.lock()
        ring.removeAll(keepingCapacity: true)
        framesReceived = 0
        callbacksReceived = 0
        inRate = 0
        inChannels = 0
        lastPeak = 0
        lock.unlock()
    }

    func setLocalMuted(_ muted: Bool) {
        localMuted = muted
        if let q = queue {
            AudioQueueSetParameter(q, kAudioQueueParam_Volume, muted ? 0 : 1)
        }
        if muted {
            lock.lock()
            ring.removeAll(keepingCapacity: true)
            lock.unlock()
        }
    }

    // MARK: - PCM from Rust (decode thread) — any rate/channels

    fileprivate func enqueue(samples: UnsafePointer<Float>, count: Int, rate: UInt32, ch: UInt16) {
        guard count > 0, ch > 0, rate >= 8000 else { return }
        if localMuted { return }

        let chIn = Int(ch)
        let framesIn = count / chIn
        guard framesIn > 0 else { return }

        // Peak for diagnostics (is the signal silent zeros?).
        var peak: Float = 0
        for i in 0..<min(count, 512) {
            peak = max(peak, abs(samples[i]))
        }

        // Resample + upmix/downmix → stereo @ 48k interleaved.
        let converted = Self.convert(
            samples: samples,
            framesIn: framesIn,
            chIn: chIn,
            rateIn: Double(rate),
            rateOut: outRate,
            chOut: Int(outChannels)
        )

        lock.lock()
        callbacksReceived &+= 1
        let n = callbacksReceived
        framesReceived &+= UInt64(framesIn)
        lastPeak = max(lastPeak * 0.9, peak)
        inRate = Double(rate)
        inChannels = chIn
        ring.append(contentsOf: converted)
        if ring.count > maxRingSamples {
            ring.removeFirst(ring.count - maxRingSamples)
        }
        let ringN = ring.count
        let needQueue = !running
        lock.unlock()

        if n == 1 || n % 100 == 0 {
            NSLog(
                "RemoteAudioPlayer: pcm#\(n) in=\(rate)Hz×\(ch) peak=\(String(format: "%.4f", peak)) ring=\(ringN) run=\(running)"
            )
        }

        if needQueue {
            DispatchQueue.main.async { [weak self] in
                self?.ensureQueue()
            }
        }
    }

    // MARK: - Resample (linear) + channel map → stereo interleaved

    private static func convert(
        samples: UnsafePointer<Float>,
        framesIn: Int,
        chIn: Int,
        rateIn: Double,
        rateOut: Double,
        chOut: Int
    ) -> [Float] {
        if framesIn <= 0 { return [] }

        // Fast path: already 48k stereo interleaved — still apply make-up gain.
        if abs(rateIn - rateOut) < 1, chIn == chOut {
            var a = Array(UnsafeBufferPointer(start: samples, count: framesIn * chIn))
            for i in a.indices {
                a[i] = max(-1, min(1, a[i] * 2.5))
            }
            return a
        }

        let framesOut = max(1, Int((Double(framesIn) * rateOut / rateIn).rounded()))
        var out = [Float](repeating: 0, count: framesOut * chOut)
        let ratio = rateIn / rateOut

        for fo in 0..<framesOut {
            let srcPos = Double(fo) * ratio
            let i0 = min(framesIn - 1, Int(srcPos))
            let i1 = min(framesIn - 1, i0 + 1)
            let frac = Float(srcPos - Double(i0))

            // Mix input channels to mono first, then duplicate to stereo (simple & clear).
            var m0: Float = 0
            var m1: Float = 0
            for c in 0..<chIn {
                m0 += samples[i0 * chIn + c]
                m1 += samples[i1 * chIn + c]
            }
            m0 /= Float(chIn)
            m1 /= Float(chIn)
            // Mild make-up gain — remote Opus is often quiet vs local media.
            var mono = (m0 + (m1 - m0) * frac) * 2.5
            mono = max(-1, min(1, mono))

            let base = fo * chOut
            for c in 0..<chOut {
                out[base + c] = mono
            }
        }
        return out
    }

    // MARK: - Session

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // moviePlayback tends to route more aggressively to speakers.
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setPreferredSampleRate(outRate)
            try session.setPreferredIOBufferDuration(0.02)
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

    // MARK: - AudioQueue @ 48k stereo float

    private func ensureQueue() {
        precondition(Thread.isMainThread)
        if running, queue != nil { return }
        disposeQueue()
        configureSession()

        var asbd = AudioStreamBasicDescription(
            mSampleRate: outRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: outBytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: outBytesPerFrame,
            mChannelsPerFrame: outChannels,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var q: AudioQueueRef?
        let user = Unmanaged.passUnretained(self).toOpaque()
        var status = AudioQueueNewOutput(
            &asbd,
            aqCallback,
            user,
            nil,
            nil,
            0,
            &q
        )
        guard status == noErr, let queue = q else {
            NSLog("RemoteAudioPlayer: AudioQueueNewOutput \(status)")
            return
        }

        // Full volume.
        AudioQueueSetParameter(queue, kAudioQueueParam_Volume, localMuted ? 0 : 1)

        let bufBytes = bufferFrames * outBytesPerFrame
        aqBuffers.removeAll()
        for _ in 0..<bufferCount {
            var buf: AudioQueueBufferRef?
            status = AudioQueueAllocateBuffer(queue, bufBytes, &buf)
            guard status == noErr, let buf else { continue }
            aqBuffers.append(buf)
            // Prime
            memset(buf.pointee.mAudioData, 0, Int(bufBytes))
            buf.pointee.mAudioDataByteSize = bufBytes
            AudioQueueEnqueueBuffer(queue, buf, 0, nil)
        }

        status = AudioQueueStart(queue, nil)
        if status == noErr {
            self.queue = queue
            running = true
            NSLog("RemoteAudioPlayer: AudioQueue 48k stereo started (bufs=\(aqBuffers.count))")
        } else {
            NSLog("RemoteAudioPlayer: AudioQueueStart \(status)")
            AudioQueueDispose(queue, true)
            running = false
        }
    }

    private func disposeQueue() {
        if let queue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
        }
        queue = nil
        aqBuffers.removeAll()
        running = false
    }

    /// Realtime AudioQueue thread: pull stereo@48k from ring into buffer.
    fileprivate func fill(buffer: AudioQueueBufferRef) {
        let frames = Int(bufferFrames)
        let ch = Int(outChannels)
        let need = frames * ch
        let dst = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)

        lock.lock()
        let available = min(need, ring.count)
        if available > 0 {
            for i in 0..<available {
                dst[i] = ring[i]
            }
            ring.removeFirst(available)
        }
        lock.unlock()

        if available < need {
            for i in available..<need {
                dst[i] = 0
            }
        }

        buffer.pointee.mAudioDataByteSize = bufferFrames * outBytesPerFrame
        if let queue {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
    }

    // MARK: - Rust bridge

    private func registerRustCallback() {
        let user = Unmanaged.passUnretained(self).toOpaque()
        rd_set_pcm_callback(pcmTrampoline, user)
    }

    private func clearRustCallback() {
        rd_set_pcm_callback(nil, nil)
    }
}

// MARK: - C callbacks

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

private let aqCallback: AudioQueueOutputCallback = { user, _, buffer in
    guard let user else { return }
    let player = Unmanaged<RemoteAudioPlayer>.fromOpaque(user).takeUnretainedValue()
    player.fill(buffer: buffer)
}
