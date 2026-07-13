import UIKit

/// Soft keyboard host: a **1×1 non-interactive** window that only owns first-responder
/// status for the system keyboard.
///
/// Important:
/// - Must NOT sit full-screen over the session UI (that blocked sidebar taps).
/// - After the keyboard is up, the **main session window is made key again** so
///   touches (sidebar, canvas) go to the remote session. The text field can stay
///   first responder without its window remaining key.
final class SoftKeyboardHost: NSObject, UITextFieldDelegate {
    static let shared = SoftKeyboardHost()

    var onInsert: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onHide: (() -> Void)?

    private var isShowing = false
    private let sentinel = "\u{200B}"
    private weak var mainWindow: UIWindow?

    private lazy var keyboardWindow: UIWindow = {
        // Tiny, off the interactive area — never covers sidebar or canvas.
        let w = UIWindow(frame: CGRect(x: -2, y: -2, width: 1, height: 1))
        w.backgroundColor = .clear
        w.windowLevel = .normal + 1
        w.isHidden = true
        // Critical: never participate in hit-testing.
        w.isUserInteractionEnabled = false
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        vc.view.isUserInteractionEnabled = false
        w.rootViewController = vc
        return w
    }()

    private lazy var field: UITextField = {
        let f = UITextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
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
        f.isUserInteractionEnabled = false
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
                // If we still think we're showing but field lost FR, sync UI.
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

    func show(in scene: UIWindowScene?) {
        let scene = scene
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { return }

        keyboardWindow.windowScene = scene
        // Remember the real app window so we can restore key status for taps.
        mainWindow = scene.windows
            .filter { $0 !== keyboardWindow && !$0.isHidden }
            .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
            .first

        keyboardWindow.frame = CGRect(x: -2, y: -2, width: 1, height: 1)
        keyboardWindow.isUserInteractionEnabled = false

        if field.superview == nil {
            let host = keyboardWindow.rootViewController!.view!
            host.isUserInteractionEnabled = false
            field.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            host.addSubview(field)
        }

        isShowing = true
        keyboardWindow.isHidden = false
        field.text = sentinel

        // Briefly become key so the keyboard attaches, then hand key status back
        // to the session window so sidebar/canvas receive taps.
        keyboardWindow.makeKeyAndVisible()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShowing else { return }
            _ = self.field.becomeFirstResponder()
            // Restore main window as key — keyboard stays if field remains FR.
            self.restoreMainKeyWindow()
            // One more pass after keyboard animation starts.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.restoreMainKeyWindow()
            }
        }
    }

    func hide(notify: Bool) {
        guard isShowing || field.isFirstResponder else { return }
        isShowing = false
        field.resignFirstResponder()
        keyboardWindow.isHidden = true
        restoreMainKeyWindow()
        if notify {
            onHide?()
        }
    }

    private func restoreMainKeyWindow() {
        if let main = mainWindow, !main.isHidden {
            main.makeKey()
            return
        }
        if let scene = keyboardWindow.windowScene {
            scene.windows
                .filter { $0 !== keyboardWindow && !$0.isHidden }
                .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
                .first?
                .makeKey()
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
