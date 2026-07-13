import AVFoundation
import Foundation

/// Plays remote desktop audio delivered as interleaved f32 PCM from Rust Opus decode.
///
/// Threading: `enqueue` is called from the Rust audio thread. The engine render
/// callback runs on the audio I/O thread. A mutex + array ring bridges them.
///
/// Important: `AVAudioSourceNode` requires a **non-interleaved** float format.
/// Rust delivers interleaved PCM; we deinterleave in the render callback.
final class RemoteAudioPlayer {
    static let shared = RemoteAudioPlayer()

    private let lock = NSLock()
    /// Interleaved f32 from Rust (L R L R …).
    private var ring: [Float] = []
    private let maxRingSamples = 48_000 * 2 * 2 // ~2s stereo @ 48k
    private var sampleRate: Double = 0
    private var channels: AVAudioChannelCount = 0

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var running = false
    /// True while mute UI wants silence (local, instant).
    private var localMuted = false

    private(set) var framesReceived: UInt64 = 0

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    deinit {
        stop()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public

    func start() {
        configureSession()
        registerRustCallback()
    }

    func stop() {
        clearRustCallback()
        DispatchQueue.main.async { [weak self] in
            self?.stopEngine()
        }
        lock.lock()
        ring.removeAll(keepingCapacity: true)
        framesReceived = 0
        sampleRate = 0
        channels = 0
        lock.unlock()
        // Don't deactivate session aggressively — can fail mid-lifecycle.
    }

    func setLocalMuted(_ muted: Bool) {
        localMuted = muted
        if muted {
            lock.lock()
            ring.removeAll(keepingCapacity: true)
            lock.unlock()
        }
    }

    // MARK: - PCM from Rust (audio decode thread)

    fileprivate func enqueue(samples: UnsafePointer<Float>, count: Int, rate: UInt32, ch: UInt16) {
        guard count > 0, ch > 0, rate > 0 else { return }
        if localMuted { return }

        let rateD = Double(rate)
        let chCount = AVAudioChannelCount(ch)

        lock.lock()
        framesReceived &+= UInt64(count / max(1, Int(ch)))
        let formatChanged = sampleRate < 1
            || abs(rateD - sampleRate) > 1
            || chCount != channels
        sampleRate = rateD
        channels = max(1, chCount)

        let buf = UnsafeBufferPointer(start: samples, count: count)
        ring.append(contentsOf: buf)
        if ring.count > maxRingSamples {
            ring.removeFirst(ring.count - maxRingSamples)
        }
        let needStart = !running || formatChanged
        lock.unlock()

        if needStart {
            DispatchQueue.main.async { [weak self] in
                self?.restartEngine()
            }
        }
    }

    // MARK: - Session / engine

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Keep options minimal — .allowBluetoothA2DP + .mixWithOthers has
            // returned OSStatus -50 (paramErr) on some iPadOS builds.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            // Fallback without options.
            do {
                try session.setCategory(.playback)
                try session.setActive(true)
            } catch {
                NSLog("RemoteAudioPlayer: AVAudioSession error \(error)")
            }
        }
    }

    private func restartEngine() {
        precondition(Thread.isMainThread)
        stopEngine()
        configureSession()

        lock.lock()
        let rate = sampleRate
        let ch = channels
        lock.unlock()

        guard rate >= 8000, ch >= 1, ch <= 8 else {
            NSLog("RemoteAudioPlayer: waiting for valid format (rate=\(rate) ch=\(ch))")
            return
        }

        // Non-interleaved is required for AVAudioSourceNode (interleaved → -10868).
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: ch,
            interleaved: false
        ) else {
            NSLog("RemoteAudioPlayer: bad format \(rate) Hz \(ch) ch")
            return
        }

        let eng = AVAudioEngine()
        let channelCount = Int(ch)

        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let frames = Int(frameCount)
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= channelCount else { return noErr }

            self.lock.lock()
            let availableFrames = min(frames, self.ring.count / max(1, channelCount))
            if availableFrames > 0 {
                // Deinterleave LRLR… → plane 0, plane 1, …
                for f in 0..<availableFrames {
                    let base = f * channelCount
                    for c in 0..<channelCount {
                        if let mData = abl[c].mData {
                            mData.assumingMemoryBound(to: Float.self)[f] = self.ring[base + c]
                        }
                    }
                }
                self.ring.removeFirst(availableFrames * channelCount)
            }
            self.lock.unlock()

            // Silence underrun / remaining frames.
            for c in 0..<channelCount {
                guard let mData = abl[c].mData else { continue }
                let plane = mData.assumingMemoryBound(to: Float.self)
                if availableFrames < frames {
                    for f in availableFrames..<frames {
                        plane[f] = 0
                    }
                }
                abl[c].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
            }
            return noErr
        }

        eng.attach(node)
        // Connect with explicit non-interleaved format.
        eng.connect(node, to: eng.mainMixerNode, format: format)
        eng.mainMixerNode.outputVolume = 1.0

        do {
            // Prepare before start reduces first-packet glitches.
            eng.prepare()
            try eng.start()
            engine = eng
            sourceNode = node
            running = true
            NSLog("RemoteAudioPlayer: started \(Int(rate)) Hz, \(ch) ch (non-interleaved)")
        } catch {
            NSLog("RemoteAudioPlayer: engine start failed \(error)")
            eng.detach(node)
            running = false
        }
    }

    private func stopEngine() {
        if let eng = engine {
            if eng.isRunning {
                eng.stop()
            }
            if let node = sourceNode {
                eng.detach(node)
            }
        }
        engine = nil
        sourceNode = nil
        running = false
    }

    // MARK: - Rust callback bridge

    private func registerRustCallback() {
        let user = Unmanaged.passUnretained(self).toOpaque()
        rd_set_pcm_callback(remoteAudioPcmTrampoline, user)
    }

    private func clearRustCallback() {
        rd_set_pcm_callback(nil, nil)
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeVal)
        else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                self.stopEngine()
            case .ended:
                self.configureSession()
                self.restartEngine()
            @unknown default:
                break
            }
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }
            self.restartEngine()
        }
    }
}

/// C trampoline — free function for `@convention(c)`.
private func remoteAudioPcmTrampoline(
    user: UnsafeMutableRawPointer?,
    samples: UnsafePointer<Float>?,
    sampleCount: Int,
    sampleRate: UInt32,
    channels: UInt16
) {
    guard let user, let samples, sampleCount > 0 else { return }
    let player = Unmanaged<RemoteAudioPlayer>.fromOpaque(user).takeUnretainedValue()
    player.enqueue(samples: samples, count: sampleCount, rate: sampleRate, ch: channels)
}
