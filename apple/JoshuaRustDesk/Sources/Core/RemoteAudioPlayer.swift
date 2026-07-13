import AVFoundation
import Foundation

/// Plays remote desktop audio delivered as interleaved f32 PCM from Rust Opus decode.
///
/// Threading: `enqueue` is called from the Rust audio thread. The engine render
/// callback runs on the audio I/O thread. A lock-free-ish ring (mutex + array)
/// bridges them with short critical sections.
final class RemoteAudioPlayer {
    static let shared = RemoteAudioPlayer()

    private let lock = NSLock()
    private var ring: [Float] = []
    private let maxRingSamples = 48_000 * 2 * 2 // ~2s stereo @ 48k
    private var sampleRate: Double = 48_000
    private var channels: AVAudioChannelCount = 2

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var running = false
    private var sessionConfigured = false

    /// Total PCM frames received (for debug HUD).
    private(set) var framesReceived: UInt64 = 0

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    deinit {
        stop()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public

    /// Activate session + register PCM callback with Rust.
    func start() {
        configureSession()
        registerRustCallback()
        // Engine is created lazily on first PCM packet (format known then).
    }

    func stop() {
        clearRustCallback()
        stopEngine()
        lock.lock()
        ring.removeAll(keepingCapacity: true)
        framesReceived = 0
        lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        sessionConfigured = false
    }

    /// Instant local mute without waiting for peer option round-trip.
    func setLocalMuted(_ muted: Bool) {
        // Drop buffered audio when muting so unmute is clean.
        if muted {
            lock.lock()
            ring.removeAll(keepingCapacity: true)
            lock.unlock()
        }
    }

    // MARK: - PCM from Rust

    fileprivate func enqueue(samples: UnsafePointer<Float>, count: Int, rate: UInt32, ch: UInt16) {
        guard count > 0, ch > 0 else { return }
        let rateD = Double(rate)
        let chCount = AVAudioChannelCount(ch)

        lock.lock()
        framesReceived &+= UInt64(count / Int(ch))
        // Recreate engine if format changes.
        let formatChanged = abs(rateD - sampleRate) > 1 || chCount != channels
        sampleRate = rateD
        channels = max(1, chCount)
        // Append
        let buf = UnsafeBufferPointer(start: samples, count: count)
        ring.append(contentsOf: buf)
        if ring.count > maxRingSamples {
            let drop = ring.count - maxRingSamples
            ring.removeFirst(drop)
        }
        let needStart = !running || formatChanged
        lock.unlock()

        if needStart {
            DispatchQueue.main.async { [weak self] in
                self?.restartEngine()
            }
        }
    }

    // MARK: - Engine

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .allowBluetoothA2DP])
            try session.setActive(true)
            sessionConfigured = true
        } catch {
            NSLog("RemoteAudioPlayer: AVAudioSession error \(error)")
        }
    }

    private func restartEngine() {
        stopEngine()
        configureSession()

        let eng = AVAudioEngine()
        let rate = sampleRate
        let ch = channels
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: ch,
            interleaved: true
        ) else {
            NSLog("RemoteAudioPlayer: bad format \(rate) Hz \(ch) ch")
            return
        }

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count > 0, let mData = abl[0].mData else { return noErr }
            let out = mData.assumingMemoryBound(to: Float.self)
            let needed = Int(frameCount) * Int(ch)

            self.lock.lock()
            let available = min(needed, self.ring.count)
            if available > 0 {
                for i in 0..<available {
                    out[i] = self.ring[i]
                }
                self.ring.removeFirst(available)
            }
            self.lock.unlock()

            // Pad underrun with silence.
            if available < needed {
                for i in available..<needed {
                    out[i] = 0
                }
            }
            abl[0].mDataByteSize = UInt32(needed * MemoryLayout<Float>.size)
            return noErr
        }

        eng.attach(node)
        eng.connect(node, to: eng.mainMixerNode, format: format)
        eng.mainMixerNode.outputVolume = 1.0

        do {
            try eng.start()
            engine = eng
            sourceNode = node
            running = true
            NSLog("RemoteAudioPlayer: started \(Int(rate)) Hz, \(ch) ch")
        } catch {
            NSLog("RemoteAudioPlayer: engine start failed \(error)")
            eng.detach(node)
            running = false
        }
    }

    private func stopEngine() {
        if let eng = engine {
            eng.stop()
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
        // Pass unmanaged self; lifetime tied to start/stop.
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
        switch type {
        case .began:
            stopEngine()
        case .ended:
            configureSession()
            restartEngine()
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        // Recreate engine on route changes (speaker ↔ BT).
        if running {
            restartEngine()
        }
    }
}

/// C trampoline — must be a free function for `@convention(c)`.
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
