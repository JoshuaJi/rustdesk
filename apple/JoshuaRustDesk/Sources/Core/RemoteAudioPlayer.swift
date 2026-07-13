import AVFoundation
import Foundation

/// Plays remote desktop audio (interleaved f32 PCM from Rust Opus decode).
///
/// Uses `AVAudioPlayerNode` + scheduled `AVAudioPCMBuffer`s — more reliable for
/// packet streaming than `AVAudioSourceNode` (which was silent / crashed with
/// interleaved formats).
final class RemoteAudioPlayer {
    static let shared = RemoteAudioPlayer()

    private let lock = NSLock()
    private var sampleRate: Double = 0
    private var channels: AVAudioChannelCount = 0

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var running = false
    private var localMuted = false
    private var pendingStart = false

    /// Soft backlog limit: drop old buffers if player falls behind.
    private var scheduledBuffers = 0
    private let maxScheduledBuffers = 24

    private(set) var framesReceived: UInt64 = 0
    private(set) var buffersPlayed: UInt64 = 0

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
        NSLog("RemoteAudioPlayer: start (callback registered)")
    }

    func stop() {
        clearRustCallback()
        let work = { [weak self] in self?.teardownEngine() }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        lock.lock()
        framesReceived = 0
        buffersPlayed = 0
        scheduledBuffers = 0
        sampleRate = 0
        channels = 0
        pendingStart = false
        lock.unlock()
    }

    func setLocalMuted(_ muted: Bool) {
        localMuted = muted
        DispatchQueue.main.async { [weak self] in
            self?.player?.volume = muted ? 0 : 1
        }
    }

    // MARK: - PCM from Rust (decode thread)

    fileprivate func enqueue(samples: UnsafePointer<Float>, count: Int, rate: UInt32, ch: UInt16) {
        guard count > 0, ch > 0, rate >= 8000 else { return }
        if localMuted { return }

        let rateD = Double(rate)
        let chCount = AVAudioChannelCount(ch)
        let frames = count / Int(ch)
        guard frames > 0 else { return }

        lock.lock()
        framesReceived &+= UInt64(frames)
        let formatChanged = sampleRate < 1
            || abs(rateD - sampleRate) > 1
            || chCount != channels
        sampleRate = rateD
        channels = max(1, chCount)
        let needEngine = !running || formatChanged || pendingStart
        // Copy out of Rust-owned memory before returning.
        let copy = Array(UnsafeBufferPointer(start: samples, count: count))
        let backlog = scheduledBuffers
        lock.unlock()

        if backlog > maxScheduledBuffers {
            // Player is stuck / engine not consuming — drop this packet.
            return
        }

        if needEngine {
            lock.lock()
            pendingStart = true
            lock.unlock()
            let rateCopy = rateD
            let chCopy = chCount
            let pcm = copy
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.ensureEngine(rate: rateCopy, channels: chCopy)
                self.schedule(pcm: pcm, frames: frames, channels: Int(chCopy))
            }
        } else {
            // Schedule directly (PlayerNode is thread-safe for scheduleBuffer).
            schedule(pcm: copy, frames: frames, channels: Int(chCount))
        }
    }

    // MARK: - Engine

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            do {
                try session.setCategory(.playback)
                try session.setActive(true)
            } catch {
                NSLog("RemoteAudioPlayer: AVAudioSession error \(error)")
            }
        }
    }

    private func ensureEngine(rate: Double, channels ch: AVAudioChannelCount) {
        precondition(Thread.isMainThread)
        if running,
           let format,
           abs(format.sampleRate - rate) < 1,
           format.channelCount == ch,
           engine?.isRunning == true,
           player != nil {
            lock.lock()
            pendingStart = false
            lock.unlock()
            return
        }

        teardownEngine()
        configureSession()

        guard rate >= 8000, ch >= 1, ch <= 8 else {
            NSLog("RemoteAudioPlayer: invalid format rate=\(rate) ch=\(ch)")
            return
        }

        // Non-interleaved float is the most portable PlayerNode format on iOS.
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: ch,
            interleaved: false
        ) else {
            NSLog("RemoteAudioPlayer: could not create format")
            return
        }

        let eng = AVAudioEngine()
        let node = AVAudioPlayerNode()
        eng.attach(node)
        eng.connect(node, to: eng.mainMixerNode, format: fmt)
        eng.mainMixerNode.outputVolume = 1.0
        node.volume = localMuted ? 0 : 1

        do {
            eng.prepare()
            try eng.start()
            node.play()
            engine = eng
            player = node
            format = fmt
            running = true
            lock.lock()
            pendingStart = false
            scheduledBuffers = 0
            lock.unlock()
            NSLog("RemoteAudioPlayer: engine started \(Int(rate)) Hz × \(ch) ch (PlayerNode)")
        } catch {
            NSLog("RemoteAudioPlayer: engine start failed \(error)")
            eng.detach(node)
            running = false
        }
    }

    private func schedule(pcm: [Float], frames: Int, channels: Int) {
        guard frames > 0, channels > 0 else { return }

        // Ensure engine on main if missing.
        if !running || player == nil || format == nil {
            let rate: Double
            let ch: AVAudioChannelCount
            lock.lock()
            rate = sampleRate
            ch = channels > 0 ? AVAudioChannelCount(channels) : self.channels
            lock.unlock()
            let work = { [weak self] in
                self?.ensureEngine(rate: rate, channels: ch)
                self?.schedule(pcm: pcm, frames: frames, channels: channels)
            }
            if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
            return
        }

        guard let player, let format else { return }
        guard Int(format.channelCount) == channels else {
            // Format mismatch — rebuild on main.
            let rate = format.sampleRate
            DispatchQueue.main.async { [weak self] in
                self?.ensureEngine(rate: rate, channels: AVAudioChannelCount(channels))
                self?.schedule(pcm: pcm, frames: frames, channels: channels)
            }
            return
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)

        // Rust PCM is interleaved LRLR… — deinterleave into planar floatChannelData.
        guard let planes = buffer.floatChannelData else {
            NSLog("RemoteAudioPlayer: buffer has no floatChannelData")
            return
        }
        for f in 0..<frames {
            let base = f * channels
            for c in 0..<channels {
                planes[c][f] = pcm[base + c]
            }
        }

        lock.lock()
        scheduledBuffers += 1
        let nSched = scheduledBuffers
        let nRecv = framesReceived
        lock.unlock()

        if nRecv % 200 == 0 {
            NSLog("RemoteAudioPlayer: recv=\(nRecv) frames, scheduled=\(nSched)")
        }

        player.scheduleBuffer(buffer, completionHandler: { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
            self.buffersPlayed &+= 1
            self.lock.unlock()
        })

        if !player.isPlaying {
            player.play()
        }
    }

    private func teardownEngine() {
        if let player {
            player.stop()
            player.reset()
        }
        if let eng = engine {
            if eng.isRunning { eng.stop() }
            if let player { eng.detach(player) }
        }
        engine = nil
        player = nil
        format = nil
        running = false
        lock.lock()
        scheduledBuffers = 0
        lock.unlock()
    }

    // MARK: - Rust bridge

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
                self.teardownEngine()
            case .ended:
                self.configureSession()
                let rate: Double
                let ch: AVAudioChannelCount
                self.lock.lock()
                rate = self.sampleRate
                ch = self.channels
                self.lock.unlock()
                if rate >= 8000, ch >= 1 {
                    self.ensureEngine(rate: rate, channels: ch)
                }
            @unknown default:
                break
            }
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }
            let rate: Double
            let ch: AVAudioChannelCount
            self.lock.lock()
            rate = self.sampleRate
            ch = self.channels
            self.lock.unlock()
            if rate >= 8000, ch >= 1 {
                self.ensureEngine(rate: rate, channels: ch)
            }
        }
    }
}

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
