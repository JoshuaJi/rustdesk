import UIKit
import Flutter

/// Flutter host that can claim hardware-keyboard shortcuts before iPadOS.
///
/// When `captureSystemShortcuts` is enabled:
/// 1. Registers `UIKeyCommand`s with `wantsPriorityOverSystemBehavior` (iOS 15+)
///    so combos like ⌘C / ⌘V reach the app instead of the system.
/// 2. Forwards `pressesBegan` / `pressesEnded` to Dart over a MethodChannel
///    so the remote peer receives the key (and we skip `super` to avoid double
///    delivery through Flutter's HardwareKeyboard).
///
/// Reserved OS shortcuts (⌘Tab, Spotlight, Siri, etc.) still cannot be stolen.
final class HardwareKeyboardCaptureViewController: FlutterViewController {
  static weak var shared: HardwareKeyboardCaptureViewController?

  private var channel: FlutterMethodChannel?
  private(set) var captureSystemShortcuts = false
  private var cachedPriorityCommands: [UIKeyCommand]?

  override func viewDidLoad() {
    super.viewDidLoad()
    HardwareKeyboardCaptureViewController.shared = self
  }

  func setupChannel(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(
      name: "org.rustdesk.rustdesk/ios_keyboard",
      binaryMessenger: messenger
    )
    channel = ch
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "gone", message: "controller deallocated", details: nil))
        return
      }
      switch call.method {
      case "setCaptureSystemShortcuts":
        let enabled = (call.arguments as? Bool) ?? false
        self.setCaptureEnabled(enabled)
        result(nil)
      case "getCaptureSystemShortcuts":
        result(self.captureSystemShortcuts)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func setCaptureEnabled(_ enabled: Bool) {
    captureSystemShortcuts = enabled
    // Force keyCommands re-query.
    cachedPriorityCommands = nil
    if enabled {
      _ = view.becomeFirstResponder()
      // Reload commands so wantsPriorityOverSystemBehavior takes effect.
      if #available(iOS 15.0, *) {
        // Touching keyCommands is enough; resign/rebecome refreshes the menu.
        let wasFirst = view.isFirstResponder
        if wasFirst {
          view.resignFirstResponder()
          _ = view.becomeFirstResponder()
        }
      }
    }
  }

  // MARK: - Claim system shortcuts (iOS 15+)

  override var keyCommands: [UIKeyCommand]? {
    guard captureSystemShortcuts else { return super.keyCommands }
    if let cached = cachedPriorityCommands {
      return cached
    }
    let built = Self.buildPriorityCommands(action: #selector(priorityCommandFired(_:)))
    cachedPriorityCommands = built
    return built
  }

  /// Registered only so `wantsPriorityOverSystemBehavior` steals the shortcut
  /// from iPadOS. Actual down/up is delivered via `pressesBegan` / `pressesEnded`
  /// once the system yields — do not synthesize here or keys double-fire.
  @objc private func priorityCommandFired(_ sender: UIKeyCommand) {
    // Intentionally empty.
  }

  // MARK: - Raw press stream

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    guard captureSystemShortcuts else {
      super.pressesBegan(presses, with: event)
      return
    }
    handlePresses(presses, down: true)
    // Do not call super: avoids Flutter HardwareKeyboard double-delivery.
  }

  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    guard captureSystemShortcuts else {
      super.pressesEnded(presses, with: event)
      return
    }
    handlePresses(presses, down: false)
  }

  override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    guard captureSystemShortcuts else {
      super.pressesCancelled(presses, with: event)
      return
    }
    handlePresses(presses, down: false)
  }

  private func handlePresses(_ presses: Set<UIPress>, down: Bool) {
    for press in presses {
      guard let key = press.key else { continue }
      // UIKeyboardHIDUsage raw values match USB HID keyboard page usages.
      let usage = UInt16(key.keyCode.rawValue & 0xFFFF)
      let chars = key.charactersIgnoringModifiers
      emitKey(usbHid: usage, down: down, characters: chars)
    }
  }

  private func emitKey(usbHid: UInt16, down: Bool, characters: String) {
    // Ignore "reserved" zero usage.
    guard usbHid != 0 else { return }
    channel?.invokeMethod("onHardwareKey", arguments: [
      "usbHid": Int(usbHid),
      "down": down,
      "characters": characters,
    ])
  }

  // MARK: - Command table

  private static func buildPriorityCommands(action: Selector) -> [UIKeyCommand] {
    var commands: [UIKeyCommand] = []

    let letters = Array("abcdefghijklmnopqrstuvwxyz")
    let digits = Array("0123456789")
    var extras = ["\t", "\r", UIKeyCommand.inputEscape,
                  UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow,
                  UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow,
                  " ",
                  "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`"]
    if #available(iOS 15.0, *) {
      extras.append(UIKeyCommand.inputDelete)
    } else {
      // Backspace / delete as ASCII DEL for older iOS.
      extras.append("\u{7F}")
    }

    let inputs: [String] = letters.map(String.init) + digits.map(String.init) + extras

    // Modifier sets we want to steal from the system when possible.
    let modifierSets: [UIKeyModifierFlags] = [
      .command,
      [.command, .shift],
      [.command, .alternate],
      [.command, .control],
      [.command, .shift, .alternate],
      .control,
      [.control, .shift],
      [.control, .alternate],
      [.control, .shift, .alternate],
      .alternate,
      [.alternate, .shift],
      .shift, // alone with letters rarely system-bound; still register for F-keys path
    ]

    for mods in modifierSets {
      // Bare shift+letter is usually character case; skip pure .shift alone for a-z
      // to avoid fighting normal typing when capture is on via presses.
      if mods == .shift { continue }
      for input in inputs {
        // Skip empty.
        if input.isEmpty { continue }
        let cmd = UIKeyCommand(input: input, modifierFlags: mods, action: action)
        if #available(iOS 15.0, *) {
          cmd.wantsPriorityOverSystemBehavior = true
        }
        // Discoverability title keeps the shortcut out of the HUD noise.
        cmd.discoverabilityTitle = nil
        commands.append(cmd)
      }
    }

    // F-keys typically arrive via pressesBegan once capture is on; no need to
    // register UIKeyCommand entries for them.

    return commands
  }
}
