import UIKit
import Flutter
import GameController

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    dummyMethodToEnforceBundling()
    // Prefer hardware keyboard / pointer delivery for Bluetooth and Magic Keyboard.
    // UIApplicationSupportsIndirectInputEvents is also set in Info.plist.
    if #available(iOS 14.0, *) {
      observeHardwareInputDevices()
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  public func dummyMethodToEnforceBundling() {
    dummy_method_to_enforce_bundling()
    session_get_rgba(nil, 0)
  }

  /// Keep Flutter as first responder when Bluetooth keyboards/mice connect so
  /// keystrokes reach the Dart HardwareKeyboard / Focus path without needing
  /// the soft keyboard TextField.
  @available(iOS 14.0, *)
  private func observeHardwareInputDevices() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(hardwareKeyboardConnected),
      name: .GCKeyboardDidConnect,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(hardwareMouseConnected),
      name: .GCMouseDidConnect,
      object: nil
    )
    // If a keyboard is already connected at launch, reclaim first responder.
    if GCKeyboard.coalesced != nil {
      becomeKeyInputFirstResponder()
    }
  }

  @objc private func hardwareKeyboardConnected(_ notification: Notification) {
    becomeKeyInputFirstResponder()
  }

  @objc private func hardwareMouseConnected(_ notification: Notification) {
    becomeKeyInputFirstResponder()
  }

  private func becomeKeyInputFirstResponder() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      if let controller = self.window?.rootViewController as? FlutterViewController {
        _ = controller.view.becomeFirstResponder()
        controller.view.window?.makeKeyAndVisible()
      }
    }
  }
}
