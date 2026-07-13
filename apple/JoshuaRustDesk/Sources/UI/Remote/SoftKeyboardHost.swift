import UIKit

/// Soft keyboard host in a dedicated `UIWindow` so the system keyboard does not
/// resize the main remote-session layout (sidebar + Metal canvas).
///
/// Becoming first responder inside the main hierarchy triggers UIKit keyboard
/// avoidance on the fullScreenCover hosting controller. Hosting the field in a
/// tiny secondary window keeps the main window's frame stable.
final class SoftKeyboardHost: NSObject, UITextFieldDelegate {
    static let shared = SoftKeyboardHost()

    var onInsert: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onHide: (() -> Void)?

    private var isShowing = false
    private let sentinel = "\u{200B}"

    private lazy var keyboardWindow: UIWindow = {
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        w.backgroundColor = .clear
        w.windowLevel = .normal + 1
        w.isHidden = true
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        w.rootViewController = vc
        return w
    }()

    private lazy var field: UITextField = {
        let f = UITextField(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
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
            guard let self, self.isShowing, !self.field.isFirstResponder else { return }
            // System dismissed keyboard (e.g. HW keyboard connect).
            DispatchQueue.main.async {
                self.hide(notify: true)
            }
        }
    }

    deinit {
        if let hideObserver {
            NotificationCenter.default.removeObserver(hideObserver)
        }
    }

    func show(in scene: UIWindowScene?) {
        if let scene {
            keyboardWindow.windowScene = scene
        } else if keyboardWindow.windowScene == nil {
            keyboardWindow.windowScene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        }
        guard keyboardWindow.windowScene != nil else { return }

        if field.superview == nil {
            keyboardWindow.rootViewController?.view.addSubview(field)
        }
        isShowing = true
        keyboardWindow.isHidden = false
        // Become key so the keyboard attaches to this window, not the main session window.
        keyboardWindow.makeKeyAndVisible()
        field.text = sentinel
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShowing else { return }
            _ = self.field.becomeFirstResponder()
        }
    }

    func hide(notify: Bool) {
        guard isShowing || field.isFirstResponder else { return }
        isShowing = false
        field.resignFirstResponder()
        keyboardWindow.isHidden = true
        // Restore key window to the main app window so touches route normally.
        if let scene = keyboardWindow.windowScene {
            scene.windows
                .filter { $0 !== keyboardWindow && !$0.isHidden }
                .last?
                .makeKey()
        }
        if notify {
            onHide?()
        }
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
            // Return — send as text; session can map later if needed.
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
