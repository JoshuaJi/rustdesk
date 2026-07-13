import UIKit

/// Soft keyboard via a **pass-through key window**.
///
/// The window stays **key** while the soft keyboard is up (iOS binds the keyboard
/// to the key window's first responder). `hitTest` always returns `nil` so
/// sidebar/canvas taps fall through to the session window.
///
/// Re-show reliability (the "works once" bug):
/// - Generation token: stale `keyboardDidHide` from a previous dismiss cannot
///   cancel a brand-new show.
/// - Every show does resign → async becomeFirstResponder.
/// - After repeated FR failures, the UITextField is recreated.
final class SoftKeyboardHost: NSObject, UITextFieldDelegate {
    static let shared = SoftKeyboardHost()

    var onInsert: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onHide: (() -> Void)?

    private(set) var isShowing = false
    /// True when our field currently owns first responder.
    var isFieldFirstResponder: Bool { field.isFirstResponder }

    private let sentinel = "\u{200B}"
    private weak var mainWindow: UIWindow?
    private var hideObserver: NSObjectProtocol?
    private var showRetry = 0
    /// Invalidates in-flight show retries and stale keyboardDidHide handlers.
    private var generation: UInt64 = 0
    private var focusWorkItem: DispatchWorkItem?

    private lazy var keyboardWindow: PassThroughWindow = {
        let w = PassThroughWindow(frame: UIScreen.main.bounds)
        w.backgroundColor = .clear
        // Above session UI for key status; system keyboard window is much higher.
        w.windowLevel = .normal + 1
        w.isHidden = true
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        w.rootViewController = vc
        return w
    }()

    private var field: UITextField = SoftKeyboardHost.makeField()

    private override init() {
        super.init()
        hideObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardDidHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isShowing else { return }
            let gen = self.generation
            // Debounce: hide during our own resign→become re-show must not tear down.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                guard self.generation == gen, self.isShowing else { return }
                if !self.field.isFirstResponder {
                    self.hide(notify: true)
                }
            }
        }
    }

    deinit {
        if let hideObserver {
            NotificationCenter.default.removeObserver(hideObserver)
        }
        focusWorkItem?.cancel()
    }

    private static func makeField() -> UITextField {
        let f = UITextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.spellCheckingType = .no
        f.smartDashesType = .no
        f.smartQuotesType = .no
        f.smartInsertDeleteType = .no
        f.keyboardType = .default
        f.returnKeyType = .default
        f.textContentType = nil
        f.alpha = 0.02
        f.tintColor = .clear
        f.textColor = .clear
        f.backgroundColor = .clear
        f.isEnabled = true
        f.isUserInteractionEnabled = true
        f.isAccessibilityElement = false
        f.text = "\u{200B}"
        return f
    }

    /// Show soft keyboard. Prefer `attachedTo` for scene resolution.
    func show(attachedTo hostView: UIView) {
        show(in: hostView.window?.windowScene)
    }

    func show(in scene: UIWindowScene?) {
        let scene = scene
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { return }

        focusWorkItem?.cancel()
        generation &+= 1
        let gen = generation
        showRetry = 0

        // Remember main window for restore-on-hide (exclude our own window).
        mainWindow = scene.windows
            .filter { $0 !== keyboardWindow && !$0.isHidden }
            .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
            .first
            ?? hostKeyWindow(in: scene)

        keyboardWindow.windowScene = scene
        keyboardWindow.frame = scene.coordinateSpace.bounds
        keyboardWindow.isHidden = false

        installFieldIfNeeded()
        field.isEnabled = true
        field.isHidden = false
        field.text = sentinel
        isShowing = true

        // Critical: this window stays KEY while the soft keyboard is up.
        keyboardWindow.makeKeyAndVisible()

        // Hard FR cycle — required for second+ shows after resign.
        if field.isFirstResponder {
            field.resignFirstResponder()
        }
        scheduleFocus(generation: gen, delay: 0)
    }

    private func installFieldIfNeeded() {
        field.delegate = self
        if field.superview == nil {
            let root = keyboardWindow.rootViewController!.view!
            field.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            root.addSubview(field)
        }
    }

    private func scheduleFocus(generation gen: UInt64, delay: TimeInterval) {
        focusWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.focusField(generation: gen)
        }
        focusWorkItem = work
        if delay <= 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func focusField(generation gen: UInt64) {
        guard isShowing, generation == gen else { return }

        keyboardWindow.isHidden = false
        keyboardWindow.makeKeyAndVisible()
        installFieldIfNeeded()

        // resign → become on next turn is the most reliable re-show path.
        if field.isFirstResponder {
            field.resignFirstResponder()
            scheduleFocus(generation: gen, delay: 0.05)
            return
        }

        // Nudge after first failure (iOS sometimes wedges UITextField).
        if showRetry > 0 {
            field.isEnabled = false
            field.isEnabled = true
            field.text = sentinel
        }

        let ok = field.becomeFirstResponder()
        if ok, field.isFirstResponder {
            field.reloadInputViews()
            return
        }

        showRetry += 1
        if showRetry <= 8 {
            if showRetry == 4 {
                recreateField()
            }
            scheduleFocus(generation: gen, delay: 0.08)
        }
    }

    private func recreateField() {
        let old = field
        old.delegate = nil
        old.resignFirstResponder()
        old.removeFromSuperview()
        let fresh = SoftKeyboardHost.makeField()
        fresh.delegate = self
        field = fresh
        installFieldIfNeeded()
    }

    func hide(notify: Bool) {
        focusWorkItem?.cancel()
        generation &+= 1 // invalidate in-flight focus retries + hide observers

        let wasShowing = isShowing || field.isFirstResponder
        isShowing = false

        if field.isFirstResponder {
            field.resignFirstResponder()
        }

        if !keyboardWindow.isHidden {
            keyboardWindow.isHidden = true
        }
        restoreMainKeyWindow()

        if wasShowing, notify {
            onHide?()
        }
    }

    private func hostKeyWindow(in scene: UIWindowScene) -> UIWindow? {
        scene.windows.first(where: \.isKeyWindow)
            ?? scene.windows.first(where: { !$0.isHidden && $0 !== keyboardWindow })
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

// MARK: - Pass-through window

/// Full-screen window that can be key (for keyboard FR) but never intercepts hits.
private final class PassThroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Always nil → touches fall through to the session window (sidebar/canvas).
        // The system keyboard uses a separate window and is unaffected.
        nil
    }
}
