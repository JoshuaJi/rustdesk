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
        // Match screen size but pass through touches outside the text field.
        // A 2×2 window can make iPad dock the keyboard in ways that still
        // disturb the main scene; a full transparent overlay is more stable.
        let bounds = UIScreen.main.bounds
        let w = UIWindow(frame: bounds)
        w.backgroundColor = .clear
        w.windowLevel = .alert + 1
        w.isHidden = true
        let vc = PassthroughViewController()
        vc.view.backgroundColor = .clear
        w.rootViewController = vc
        return w
    }()

    /// Root VC whose view ignores hits except the text field.
    private final class PassthroughViewController: UIViewController {
        override func loadView() {
            view = PassthroughView()
        }
    }

    private final class PassthroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let hit = super.hitTest(point, with: event)
            // Only capture hits on the text field (and its subviews); everything
            // else falls through to the remote session window underneath.
            if hit is UITextField { return hit }
            return nil
        }
    }

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
        guard let scene = keyboardWindow.windowScene else { return }

        // Keep frame in sync with the scene (rotation / multitasking).
        keyboardWindow.frame = scene.coordinateSpace.bounds

        if field.superview == nil {
            let host = keyboardWindow.rootViewController!.view!
            field.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(field)
            NSLayoutConstraint.activate([
                field.widthAnchor.constraint(equalToConstant: 1),
                field.heightAnchor.constraint(equalToConstant: 1),
                field.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                field.topAnchor.constraint(equalTo: host.topAnchor),
            ])
        }
        isShowing = true
        keyboardWindow.isHidden = false
        // Key window so the keyboard is owned by this overlay — main session
        // hosting controller must not be the keyboard layout client.
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
            // Prefer the app's primary window (lowest normal level, not our overlay).
            let main = scene.windows
                .filter { $0 !== keyboardWindow && !$0.isHidden }
                .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
                .first
            main?.makeKey()
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
