import SwiftUI
import UIKit

extension Notification.Name {
    /// Force-dismiss the full-screen remote session host (Disconnect / Cancel).
    static let porticoDismissRemoteSession = Notification.Name("porticoDismissRemoteSession")
}

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
    private var dismissObserver: NSObjectProtocol?

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
        if let dismissObserver {
            NotificationCenter.default.removeObserver(dismissObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        disableKeyboardSafeArea()
        view.insetsLayoutMarginsFromSafeArea = false
        additionalSafeAreaInsets = .zero
        dismissObserver = NotificationCenter.default.addObserver(
            forName: .porticoDismissRemoteSession,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.dismissFromPresentation(animated: true)
        }
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

    /// Dismiss this full-screen session no matter how it was presented.
    func dismissFromPresentation(animated: Bool) {
        SoftKeyboardHost.shared.hide(notify: false)
        if let presenter = presentingViewController {
            presenter.dismiss(animated: animated)
            return
        }
        dismiss(animated: animated, completion: nil)
    }

    private func disableKeyboardSafeArea() {
        if #available(iOS 16.4, *) {
            safeAreaRegions = .container
        }
        additionalSafeAreaInsets = .zero
        view.insetsLayoutMarginsFromSafeArea = false
        children.forEach { child in
            child.additionalSafeAreaInsets = .zero
            child.view.insetsLayoutMarginsFromSafeArea = false
            if #available(iOS 16.4, *) {
                let name = NSStringFromClass(type(of: child))
                if name.contains("HostingController"),
                   child.responds(to: NSSelectorFromString("setSafeAreaRegions:")) {
                    child.setValue(1, forKey: "safeAreaRegions")
                }
            }
        }
    }

    private func forceFullWindowFrame() {
        guard let window = view.window else { return }
        let target = window.bounds
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
        let anchor = UIViewController()
        anchor.view.backgroundColor = .clear
        anchor.view.isUserInteractionEnabled = false
        return anchor
    }

    func updateUIViewController(_ anchor: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.wantsPresented = isPresented

        if isPresented {
            if coordinator.host == nil {
                if anchor.presentedViewController != nil {
                    anchor.dismiss(animated: false)
                }
                Self.dismissStrayRemoteHosts()

                let host = RemoteSessionHostController(
                    rootView: RemoteSessionView(session: session, isPresented: $isPresented)
                )
                coordinator.host = host
                coordinator.presentGeneration &+= 1
                let gen = coordinator.presentGeneration

                DispatchQueue.main.async {
                    guard coordinator.presentGeneration == gen,
                          coordinator.host === host,
                          coordinator.wantsPresented,
                          anchor.view.window != nil
                    else {
                        if coordinator.host === host, !coordinator.wantsPresented {
                            coordinator.host = nil
                        }
                        return
                    }
                    if anchor.presentedViewController != nil {
                        anchor.dismiss(animated: false) {
                            guard coordinator.presentGeneration == gen,
                                  coordinator.wantsPresented,
                                  coordinator.host === host
                            else { return }
                            anchor.present(host, animated: true)
                        }
                    } else {
                        anchor.present(host, animated: true)
                    }
                }
            } else if let host = coordinator.host {
                host.rootView = RemoteSessionView(session: session, isPresented: $isPresented)
            }
        } else {
            coordinator.presentGeneration &+= 1
            SoftKeyboardHost.shared.hide(notify: false)

            let host = coordinator.host
            coordinator.host = nil

            if let host {
                host.dismissFromPresentation(animated: true)
            }
            if anchor.presentedViewController != nil {
                anchor.dismiss(animated: true)
            }
            Self.dismissStrayRemoteHosts()
        }
    }

    private static func dismissStrayRemoteHosts() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                var vc: UIViewController? = window.rootViewController
                while let current = vc {
                    if let presented = current.presentedViewController {
                        if presented is RemoteSessionHostController {
                            current.dismiss(animated: true)
                            break
                        }
                        vc = presented
                    } else {
                        break
                    }
                }
            }
        }
    }

    final class Coordinator {
        var host: RemoteSessionHostController?
        var presentGeneration: UInt = 0
        var wantsPresented = false
    }
}
