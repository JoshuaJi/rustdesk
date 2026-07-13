import SwiftUI
import UIKit

/// UIKit host for the remote session that **never** shrinks for the software keyboard.
///
/// SwiftUI `fullScreenCover` + `.ignoresSafeArea(.keyboard)` is insufficient: UIKit still
/// applies keyboard safe-area insets to the presentation hosting controller, which pushes
/// the whole HStack (sidebar + canvas) upward. This controller:
/// 1. Excludes `.keyboard` from `safeAreaRegions` (iOS 16.4+)
/// 2. Forces `view.frame = window.bounds` on every layout pass while active
/// 3. Is presented with `.overFullScreen` so the home stack is not resized either
final class RemoteSessionHostController: UIHostingController<RemoteSessionView> {
    private var keyboardObservers: [NSObjectProtocol] = []

    override init(rootView: RemoteSessionView) {
        super.init(rootView: rootView)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        view.backgroundColor = .black
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        disableKeyboardSafeArea()
        view.insetsLayoutMarginsFromSafeArea = false
        additionalSafeAreaInsets = .zero
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        disableKeyboardSafeArea()
        installKeyboardObservers()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        disableKeyboardSafeArea()
        forceFullWindowFrame()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyboardObservers.removeAll()
        SoftKeyboardHost.shared.hide(notify: false)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        forceFullWindowFrame()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        forceFullWindowFrame()
    }

    private func disableKeyboardSafeArea() {
        if #available(iOS 16.4, *) {
            // Keep notch/home-indicator container insets; drop keyboard insets.
            safeAreaRegions = .container
        }
        additionalSafeAreaInsets = .zero
        view.insetsLayoutMarginsFromSafeArea = false
        // Propagate to any child hosting controllers SwiftUI may insert.
        children.forEach { child in
            child.additionalSafeAreaInsets = .zero
            child.view.insetsLayoutMarginsFromSafeArea = false
            if #available(iOS 16.4, *) {
                let name = NSStringFromClass(type(of: child))
                if name.contains("HostingController"),
                   child.responds(to: NSSelectorFromString("setSafeAreaRegions:")) {
                    child.setValue(1, forKey: "safeAreaRegions") // .container
                }
            }
        }
    }

    private func forceFullWindowFrame() {
        guard let window = view.window else { return }
        let target = window.bounds
        // If keyboard avoidance nudged us, snap back without animation.
        if view.frame != target || view.bounds.size != target.size {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.transform = .identity
            view.bounds = CGRect(origin: .zero, size: target.size)
            view.center = CGPoint(x: target.midX, y: target.midY)
            view.frame = target
            CATransaction.commit()
        }
    }

    private func installKeyboardObservers() {
        keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyboardObservers.removeAll()
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardWillHideNotification,
            UIResponder.keyboardDidHideNotification,
        ]
        for name in names {
            keyboardObservers.append(nc.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.disableKeyboardSafeArea()
                self?.forceFullWindowFrame()
                // Run again after UIKit finishes its own keyboard animation layout.
                DispatchQueue.main.async {
                    self?.disableKeyboardSafeArea()
                    self?.forceFullWindowFrame()
                }
            })
        }
    }
}

/// Presents / dismisses `RemoteSessionHostController` from SwiftUI without `fullScreenCover`.
struct RemoteSessionPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var session: SessionController

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        // Invisible anchor VC in the hierarchy; we present from it.
        let anchor = UIViewController()
        anchor.view.backgroundColor = .clear
        anchor.view.isUserInteractionEnabled = false
        return anchor
    }

    func updateUIViewController(_ anchor: UIViewController, context: Context) {
        let coordinator = context.coordinator
        if isPresented {
            if coordinator.host == nil, anchor.presentedViewController == nil {
                let binding = $isPresented
                let root = RemoteSessionView(session: session, isPresented: binding)
                let host = RemoteSessionHostController(rootView: root)
                coordinator.host = host
                // Present after the current runloop so the anchor is in the window.
                DispatchQueue.main.async {
                    guard isPresented, anchor.presentedViewController == nil else { return }
                    anchor.present(host, animated: true)
                }
            } else if let host = coordinator.host {
                // Keep rootView's binding/session fresh.
                host.rootView = RemoteSessionView(session: session, isPresented: $isPresented)
            }
        } else {
            if let host = coordinator.host {
                SoftKeyboardHost.shared.hide(notify: false)
                if host.presentingViewController != nil {
                    host.dismiss(animated: true)
                }
                coordinator.host = nil
            } else if let presented = anchor.presentedViewController {
                presented.dismiss(animated: true)
            }
        }
    }

    final class Coordinator {
        var host: RemoteSessionHostController?
    }
}
