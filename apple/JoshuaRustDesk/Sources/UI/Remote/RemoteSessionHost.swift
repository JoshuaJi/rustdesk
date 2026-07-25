import SwiftUI
import UIKit

/// UIKit host that keeps the remote-session shell fixed while the canvas handles
/// the software-keyboard overlap explicitly.
///
/// SwiftUI `fullScreenCover` + `.ignoresSafeArea(.keyboard)` is insufficient: UIKit still
/// applies keyboard safe-area insets to the presentation hosting controller, which pushes
/// the whole HStack (sidebar + canvas) upward. This controller:
/// 1. Owns status-bar appearance so the remote session is genuinely full-screen
/// 2. Excludes `.keyboard` from `safeAreaRegions` (iOS 16.4+)
/// 3. Forces `view.frame = window.bounds` on every layout pass while active
/// 4. Leaves the canvas to inset itself by the measured keyboard overlap
/// 5. Is presented with `.fullScreen` so it owns the scene's status-bar policy
final class RemoteSessionHostController: UIHostingController<RemoteSessionView> {
    private var keyboardObservers: [NSObjectProtocol] = []

    override var prefersStatusBarHidden: Bool { true }

    override init(rootView: RemoteSessionView) {
        super.init(rootView: rootView)
        modalPresentationStyle = .fullScreen
        modalPresentationCapturesStatusBarAppearance = true
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
        setNeedsStatusBarAppearanceUpdate()
        disableKeyboardSafeArea()
        installKeyboardObservers()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsStatusBarAppearanceUpdate()
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

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.disableKeyboardSafeArea()
            self?.forceFullWindowFrame()
        }, completion: { [weak self] _ in
            self?.disableKeyboardSafeArea()
            self?.forceFullWindowFrame()
            self?.view.setNeedsLayout()
            self?.view.layoutIfNeeded()
        })
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
            if coordinator.host == nil {
                // Dismiss any stale presentation first.
                if anchor.presentedViewController != nil {
                    anchor.dismiss(animated: false)
                }
                let host = RemoteSessionHostController(
                    rootView: RemoteSessionView(session: session, isPresented: $isPresented)
                )
                coordinator.host = host
                coordinator.presentGeneration &+= 1
                let gen = coordinator.presentGeneration
                // Present after the current runloop so the anchor is in the window.
                DispatchQueue.main.async {
                    // Invalidate if disconnect already fired or a newer present was requested.
                    guard coordinator.presentGeneration == gen,
                          coordinator.host === host,
                          anchor.presentedViewController == nil
                    else { return }
                    // Re-check binding via coordinator flag set on each update.
                    guard coordinator.wantsPresented else {
                        coordinator.host = nil
                        return
                    }
                    anchor.present(host, animated: true)
                }
            } else if let host = coordinator.host {
                // Keep rootView's binding/session fresh.
                host.rootView = RemoteSessionView(session: session, isPresented: $isPresented)
            }
            coordinator.wantsPresented = true
        } else {
            coordinator.wantsPresented = false
            coordinator.presentGeneration &+= 1 // cancel any in-flight present
            SoftKeyboardHost.shared.hide(notify: false)
            if let host = coordinator.host {
                coordinator.host = nil
                if host.presentingViewController != nil {
                    host.dismiss(animated: true)
                } else if anchor.presentedViewController != nil {
                    // Presentation may still be settling; dismiss whatever is up.
                    anchor.dismiss(animated: true)
                }
            } else if anchor.presentedViewController != nil {
                anchor.dismiss(animated: true)
            }
        }
    }

    final class Coordinator {
        var host: RemoteSessionHostController?
        /// Bumped to cancel a pending async `present` after disconnect.
        var presentGeneration: UInt = 0
        /// Mirrors latest `isPresented` for the async present guard.
        var wantsPresented = false
    }
}
