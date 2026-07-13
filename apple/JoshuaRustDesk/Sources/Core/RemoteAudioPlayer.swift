import Foundation

/// Remote desktop audio player (currently **disabled**).
/// Host often does not capture system audio; beep/PCM playback stays off until re-enabled.
final class RemoteAudioPlayer {
    static let shared = RemoteAudioPlayer()

    /// Flip to `true` (and restore AudioQueue path) when host capture is reliable.
    static let isEnabled = false

    private(set) var framesReceived: UInt64 = 0
    private(set) var lastPeak: Float = 0

    private init() {}

    func start() {
        // No beep, no AVAudioSession, no Rust PCM callback.
        NSLog("RemoteAudioPlayer: disabled (start ignored)")
    }

    func stop() {}

    func setLocalMuted(_ muted: Bool) {
        _ = muted
    }
}
