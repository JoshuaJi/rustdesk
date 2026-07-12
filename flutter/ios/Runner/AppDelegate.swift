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

    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    // Wire native keyboard-capture channel after Flutter window is ready.
    if let controller = window?.rootViewController as? HardwareKeyboardCaptureViewController {
      controller.setupChannel(messenger: controller.binaryMessenger)
    } else if let controller = window?.rootViewController as? FlutterViewController {
      // Fallback if storyboard class was not updated yet.
      let channel = FlutterMethodChannel(
        name: "org.rustdesk.rustdesk/ios_keyboard",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { _, result in
        result(FlutterError(
          code: "unsupported",
          message: "HardwareKeyboardCaptureViewController not installed",
          details: nil
        ))
      }
    }

    // Prefer hardware keyboard / pointer delivery for Bluetooth and Magic Keyboard.
    if #available(iOS 14.0, *) {
      observeHardwareInputDevices()
    }
    return ok
  }

  public func dummyMethodToEnforceBundling() {
    dummy_method_to_enforce_bundling()
    session_get_rgba(nil, 0)
  }

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
