import UIKit
import GameController

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Keep rustdesk static symbols from being stripped.
        rd_force_link()
        _ = session_get_rgba(nil, 0)

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
