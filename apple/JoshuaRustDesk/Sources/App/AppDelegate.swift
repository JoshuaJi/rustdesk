import UIKit
import GameController
import AVFoundation

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Keep rustdesk static symbols from being stripped.
        rd_force_link()
        _ = session_get_rgba(nil, 0)

        // Prepare audio session early so remote desktop PCM can play.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .allowBluetoothA2DP])
        } catch {
            NSLog("AVAudioSession setup: \(error)")
        }

        if #available(iOS 14.0, *) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(inputDeviceConnected),
                name: .GCKeyboardDidConnect,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(inputDeviceConnected),
                name: .GCMouseDidConnect,
                object: nil
            )
        }
        return true
    }

    @objc private func inputDeviceConnected() {
        // Focus will be managed by RemoteSessionView when active.
    }
}
