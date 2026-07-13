import AudioToolbox
import AVFoundation
import Foundation

/// Remote desktop audio: Rust Opus → f32 PCM → **Int16 AudioQueue @ 48 kHz stereo**.
///
/// Critical fixes vs prior silent builds:
/// 1. Re-enqueue with callback's `inAQ` (not `self.queue`, which was nil during Start race).
/// 2. Assign `self.queue` **before** `AudioQueueStart`.
/// 3. Prebuffer ~150 ms before Start so we don't only play silence primes.
/// 4. Int16 interleaved (most reliable on iOS hardware path).
/// 5. Test beep on connect proves speaker path works.
final class RemoteAudioPlayer {
    static let shared = RemoteAudioPlayer()

    private let outRate: Double = 48_000
    private let outCh: Int = 2
    private var outBytesPerFrame: UInt32 { UInt32(outCh * 2) }

    private let lock = NSLock()
    /// Circular buffer of interleaved Int16 stereo @ 48k.
    private var ring: [Int16]
    private var ringRead = 0
    private var ringWrite = 0
    private var ringCount = 0
    private let ringCapacity: Int

    private var queue: AudioQueueRef?
    private var running = false
    private var starting = false
    private var localMuted = false

    private let framesPerBuffer = 960 // 20 ms
    private let bufferCount = 5
    private let prebufferFrames = 48_000 / 6 // ~167 ms stereo frames → samples = *2

    private(set) var framesReceived: UInt64 = 0
    private(set) var callbacksReceived: UInt64 = 0
    private(set) var lastPeak: Float = 0
    private(set) var fillCount: UInt64 = 0
    private(set) var underruns: UInt64 = 0

    private init() {
        // 4 seconds of stereo Int16
        ringCapacity = 48_000 * 2 * 4
        ring = [Int16](repeating: 0, count: ringCapacity)
    }

    // MARK: - Public

    func start() {
        configureSession()
        registerRustCallback()
        // Don't Start queue yet — wait for prebuffer OR start with beep for diagnostics.
        DispatchQueue.main.async { [weak self] in
            // Immediate beep proves the speaker; then we keep the queue running for PCM.
            self?.startQueue(withBeep: true)
        }
        NSLog("RemoteAudioPlayer: start")
    }

    func stop() {
        clearRustCallback()
        let work = { [weak self] in self?.disposeQueue() }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        lock.lock()
        ringRead = 0
        ringWrite = 0
        ringCount = 0
        framesReceived = 0
        callbacksReceived = 0
        fillCount = 0
        underruns = 0
        lastPeak = 0
        starting = false
        lock.unlock()
    }

    func setLocalMuted(_ muted: Bool) {
        localMuted = muted
        if let q = queue {
            AudioQueueSetParameter(q, kAudioQueueParam_Volume, muted ? 0 : 1)
        }
        if muted {
            lock.lock()
            ringRead = 0
            ringWrite = 0
            ringCount = 0
            lock.unlock()
        }
    }

    // MARK: - From Rust (any thread)

    fileprivate func enqueue(samples: UnsafePointer<Float>, count: Int, rate: UInt32, ch: UInt16) {
        guard count > 0, ch > 0, rate >= 8000 else { return }
        if localMuted { return }

        let chIn = Int(ch)
        let framesIn = count / chIn
        guard framesIn > 0 else { return }

        var peak: Float = 0
        for i in 0..<min(count, 512) {
            peak = max(peak, abs(samples[i]))
        }

        let s16 = Self.toInt16Stereo48k(
            samples: samples,
            framesIn: framesIn,
            chIn: chIn,
            rateIn: Double(rate)
        )

        lock.lock()
        callbacksReceived &+= 1
        let n = callbacksReceived
        framesReceived &+= UInt64(framesIn)
        lastPeak = max(lastPeak * 0.9, peak)
        writeRing(s16)
        let bufferedFrames = ringCount / outCh
        let isRunning = running
        let isStarting = starting
        let peakSnap = lastPeak
        lock.unlock()

        if n == 1 || n % 40 == 0 {
            NSLog(
                "RemoteAudioPlayer: pcm#\(n) \(rate)Hz×\(ch) peak=\(String(format: "%.4f", peakSnap)) bufFrames=\(bufferedFrames) run=\(isRunning)"
            )
        }

        if !isRunning && !isStarting && bufferedFrames >= prebufferFrames {
            DispatchQueue.main.async { [weak self] in
                self?.startQueue(withBeep: false)
            }
        }
    }

    // MARK: - Ring (O(1) write/read)

    private func writeRing(_ samples: [Int16]) {
        for s in samples {
            if ringCount >= ringCapacity {
                // Drop oldest sample pair-ish: advance read
                ringRead = (ringRead + 1) % ringCapacity
                ringCount -= 1
            }
            ring[ringWrite] = s
            ringWrite = (ringWrite + 1) % ringCapacity
            ringCount += 1
        }
    }

    private func readRing(into dst: UnsafeMutablePointer<Int16>, count: Int) -> Int {
        let n = min(count, ringCount)
        for i in 0..<n {
            dst[i] = ring[ringRead]
            ringRead = (ringRead + 1) % ringCapacity
        }
        ringCount -= n
        return n
    }

    // MARK: - Convert

    private static func toInt16Stereo48k(
        samples: UnsafePointer<Float>,
        framesIn: Int,
        chIn: Int,
        rateIn: Double
    ) -> [Int16] {
        let rateOut = 48_000.0
        let framesOut = max(1, Int((Double(framesIn) * rateOut / rateIn).rounded()))
        var out = [Int16](repeating: 0, count: framesOut * 2)
        let ratio = rateIn / rateOut
        let gain: Float = 5.0

        for fo in 0..<framesOut {
            let srcPos = Double(fo) * ratio
            let i0 = min(framesIn - 1, max(0, Int(srcPos)))
            let i1 = min(framesIn - 1, i0 + 1)
            let frac = Float(srcPos - Double(i0))

            var m0: Float = 0
            var m1: Float = 0
            for c in 0..<chIn {
                m0 += samples[i0 * chIn + c]
                m1 += samples[i1 * chIn + c]
            }
            m0 /= Float(max(1, chIn))
            m1 /= Float(max(1, chIn))
            var mono = (m0 + (m1 - m0) * frac) * gain
            mono = max(-1, min(1, mono))
            let s = Int16((mono * 32767).rounded())
            out[fo * 2] = s
            out[fo * 2 + 1] = s
        }
        return out
    }

    // MARK: - Session

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setPreferredSampleRate(outRate)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
            try? session.overrideOutputAudioPort(.speaker)
        } catch {
            NSLog("RemoteAudioPlayer: session error \(error)")
            try? session.setCategory(.playback)
            try? session.setActive(true)
        }
        let outs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
        NSLog("RemoteAudioPlayer: session ok rate=\(session.sampleRate) outs=\(outs)")
    }

    // MARK: - AudioQueue

    private func startQueue(withBeep: Bool) {
        precondition(Thread.isMainThread)
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        starting = true
        lock.unlock()

        disposeQueue()
        configureSession()

        var asbd = AudioStreamBasicDescription(
            mSampleRate: outRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger
                | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: outBytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: outBytesPerFrame,
            mChannelsPerFrame: UInt32(outCh),
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var q: AudioQueueRef?
        let user = Unmanaged.passUnretained(self).toOpaque()
        var st = AudioQueueNewOutput(&asbd, aqCallback, user, nil, nil, 0, &q)
        guard st == noErr, let queue = q else {
            NSLog("RemoteAudioPlayer: NewOutput failed \(st)")
            lock.lock(); starting = false; lock.unlock()
            return
        }

        // CRITICAL: publish queue BEFORE Start so early callbacks can re-enqueue.
        self.queue = queue
        AudioQueueSetParameter(queue, kAudioQueueParam_Volume, localMuted ? 0 : 1)

        let bufBytes = UInt32(framesPerBuffer) * outBytesPerFrame
        for i in 0..<bufferCount {
            var buf: AudioQueueBufferRef?
            st = AudioQueueAllocateBuffer(queue, bufBytes, &buf)
            guard st == noErr, let buf else {
                NSLog("RemoteAudioPlayer: AllocBuffer[\(i)] \(st)")
                continue
            }
            if withBeep, i == 0 {
                writeBeep(buf)
            } else {
                // Pull whatever is buffered, or silence.
                fillBuffer(aq: queue, buffer: buf)
            }
        }

        st = AudioQueueStart(queue, nil)
        if st == noErr {
            lock.lock()
            running = true
            starting = false
            lock.unlock()
            NSLog("RemoteAudioPlayer: STARTED s16 48k stereo beep=\(withBeep)")
        } else {
            NSLog("RemoteAudioPlayer: Start FAILED \(st)")
            disposeQueue()
            lock.lock(); starting = false; lock.unlock()
        }
    }

    private func writeBeep(_ buffer: AudioQueueBufferRef) {
        let frames = framesPerBuffer
        let dst = buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self)
        let freq = 880.0
        let amp: Double = 0.35
        for f in 0..<frames {
            let t = Double(f) / outRate
            let s = Int16(sin(2 * Double.pi * freq * t) * amp * 32767)
            dst[f * 2] = s
            dst[f * 2 + 1] = s
        }
        buffer.pointee.mAudioDataByteSize = UInt32(frames) * outBytesPerFrame
        if let queue {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
    }

    private func disposeQueue() {
        if let queue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
        }
        queue = nil
        lock.lock()
        running = false
        starting = false
        lock.unlock()
    }

    /// Realtime callback path — always re-enqueue via `aq` argument.
    fileprivate func fillBuffer(aq: AudioQueueRef, buffer: AudioQueueBufferRef) {
        let need = framesPerBuffer * outCh
        let dst = buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self)

        lock.lock()
        fillCount &+= 1
        let fc = fillCount
        let got = readRing(into: dst, count: need)
        if got < need {
            underruns &+= 1
            for i in got..<need { dst[i] = 0 }
        }
        let und = underruns
        let peak = lastPeak
        lock.unlock()

        buffer.pointee.mAudioDataByteSize = UInt32(need * MemoryLayout<Int16>.size)

        // CRITICAL: use callback's queue ref, never optional self.queue.
        let st = AudioQueueEnqueueBuffer(aq, buffer, 0, nil)
        if st != noErr {
            NSLog("RemoteAudioPlayer: re-enqueue \(st)")
        }

        if fc == 1 || fc % 250 == 0 {
            NSLog("RemoteAudioPlayer: fill#\(fc) got=\(got)/\(need) und=\(und) peak=\(String(format: "%.3f", peak))")
        }
    }

    // MARK: - Rust bridge

    private func registerRustCallback() {
        let user = Unmanaged.passUnretained(self).toOpaque()
        rd_set_pcm_callback(pcmTrampoline, user)
        NSLog("RemoteAudioPlayer: callback registered")
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
    Unmanaged<RemoteAudioPlayer>.fromOpaque(user)
        .takeUnretainedValue()
        .enqueue(samples: samples, count: sampleCount, rate: sampleRate, ch: channels)
}

private let aqCallback: AudioQueueOutputCallback = { user, inAQ, buffer in
    guard let user else { return }
    Unmanaged<RemoteAudioPlayer>.fromOpaque(user)
        .takeUnretainedValue()
        .fillBuffer(aq: inAQ, buffer: buffer)
}
