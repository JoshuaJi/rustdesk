import UIKit

/// Soft keyboard host: a **1×1 off-screen** `UITextField` attached to the remote
/// session host view (same key window as the UI).
///
/// Design goals:
/// - Keyboard appears via `becomeFirstResponder` in the **already-key** session window
/// - Field never covers sidebar/canvas (off-screen frame, no secondary overlay window)
/// - Session layout does not shrink — that is owned by `RemoteSessionHostController`
///
/// History:
/// - Full-screen secondary `UIWindow` → keyboard OK, sidebar untappable
/// - 1×1 secondary window + `makeKey()` back to main → sidebar OK, keyboard gone
///   (iOS dismisses the keyboard when the FR window loses key status)
final class SoftKeyboardHost: NSObject, UITextFieldDelegate {
    static let shared = SoftKeyboardHost()

    var onInsert: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onHide: (() -> Void)?

    private var isShowing = false
    private let sentinel = "\u{200B}"

    private lazy var field: UITextField = {
        let f = UITextField(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
        f.delegate = self
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.spellCheckingType = .no
        f.smartDashesType = .no
        f.smartQuotesType = .no
        f.smartInsertDeleteType = .no
        f.keyboardType = .default
        f.returnKeyType = .default
        f.textContentType = nil
        f.alpha = 0.01
        f.tintColor = .clear
        f.textColor = .clear
        f.backgroundColor = .clear
        // Programmatic FR works with interaction off; field never steals taps.
        // Keep isEnabled = true (UIControl) and isHidden = false (required).
        f.isEnabled = true
        f.isUserInteractionEnabled = false
        f.isAccessibilityElement = false
        f.text = sentinel
        return f
    }()

    private var hideObserver: NSObjectProtocol?

    private override init() {
        super.init()
        hideObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isShowing else { return }
            DispatchQueue.main.async {
                // User dismissed keyboard (e.g. swipe-down) — sync toolbar state.
                if self.isShowing, !self.field.isFirstResponder {
                    self.hide(notify: true)
                }
            }
        }
    }

    deinit {
        if let hideObserver {
            NotificationCenter.default.removeObserver(hideObserver)
        }
    }

    /// Show the soft keyboard by focusing a field inside `hostView`'s window.
    /// Prefer the keyboard-immune `RemoteSessionHostController.view`.
    func show(attachedTo hostView: UIView) {
        let target = preferredHostView(from: hostView)

        if field.superview !== target {
            field.removeFromSuperview()
            target.addSubview(field)
        }
        // Keep off-screen so hit-testing never hits the field.
        field.frame = CGRect(x: -100, y: -100, width: 1, height: 1)
        field.text = sentinel
        isShowing = true

        // Session host window is already key (presented overFullScreen). Ensure it.
        target.window?.makeKey()

        // Delay past the toolbar button's touch end so we don't lose FR immediately.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShowing else { return }
            self.targetWindowMakeKey(for: target)
            let ok = self.field.becomeFirstResponder()
            if !ok {
                // Retry once after layout (host may still be animating).
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isShowing else { return }
                    self.targetWindowMakeKey(for: target)
                    _ = self.field.becomeFirstResponder()
                }
            }
        }
    }

    /// Legacy entry: resolve scene → key window → attach there.
    func show(in scene: UIWindowScene?) {
        let scene = scene
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { return }
        let window = scene.windows.first(where: \.isKeyWindow)
            ?? scene.windows.first(where: { !$0.isHidden })
        guard let root = window?.rootViewController else { return }
        let host = topMost(from: root).view ?? root.view!
        show(attachedTo: host)
    }

    func hide(notify: Bool) {
        guard isShowing || field.isFirstResponder else { return }
        isShowing = false
        field.resignFirstResponder()
        // Leave field in hierarchy; cheap and avoids re-add churn.
        if notify {
            onHide?()
        }
    }

    // MARK: Host resolution

    /// Prefer `RemoteSessionHostController.view` (safeAreaRegions / forceFullWindowFrame).
    private func preferredHostView(from view: UIView) -> UIView {
        var responder: UIResponder? = view
        while let r = responder {
            if let host = r as? RemoteSessionHostController {
                return host.view
            }
            responder = r.next
        }
        // Walk VC chain from nearest.
        var vc = view.findViewController()
        while let current = vc {
            if let host = current as? RemoteSessionHostController {
                return host.view
            }
            if let presented = current.presentedViewController as? RemoteSessionHostController {
                return presented.view
            }
            vc = current.parent ?? current.presentingViewController
        }
        return view
    }

    private func targetWindowMakeKey(for view: UIView) {
        view.window?.makeKey()
    }

    private func topMost(from vc: UIViewController) -> UIViewController {
        if let presented = vc.presentedViewController {
            return topMost(from: presented)
        }
        return vc
    }

    // MARK: UITextFieldDelegate

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        if string.isEmpty {
            onDelete?()
        } else if string == "\n" {
            onInsert?("\n")
        } else {
            onInsert?(string)
        }
        textField.text = sentinel
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onInsert?("\n")
        textField.text = sentinel
        return false
    }
}

private extension UIView {
    func findViewController() -> UIViewController? {
        var r: UIResponder? = self
        while let cur = r {
            if let vc = cur as? UIViewController { return vc }
            r = cur.next
        }
        return nil
    }
}
