import SwiftUI
import UIKit

/// Prevents the system keyboard from resizing the whole remote-session layout
/// and reports its bottom overlap so the canvas can avoid it explicitly.
/// Attached as a zero-size background view via `disableKeyboardLayoutShift(keyboardOverlap:)`.
///
/// SwiftUI `.ignoresSafeArea(.keyboard)` alone is not enough inside
/// `fullScreenCover` — UIKit still applies keyboard safe-area insets to the
/// hosting controller. We strip those, re-pin the presentation root to the
/// full window bounds, and let only the remote canvas consume the overlap.
struct KeyboardLayoutFixer: UIViewRepresentable {
    @Binding var keyboardOverlap: CGFloat

    func makeUIView(context: Context) -> FixerView {
        let view = FixerView()
        view.onKeyboardOverlapChange = { keyboardOverlap = $0 }
        return view
    }

    func updateUIView(_ uiView: FixerView, context: Context) {
        uiView.onKeyboardOverlapChange = { keyboardOverlap = $0 }
    }

    final class FixerView: UIView {
        var onKeyboardOverlapChange: ((CGFloat) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastKeyboardFrame: CGRect?
        private var reportedKeyboardOverlap: CGFloat = 0

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isHidden = true
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            uninstallObservers()
            guard window != nil else {
                onKeyboardOverlapChange?(0)
                return
            }
            applyAll()
            installObservers()
            DispatchQueue.main.async { [weak self] in
                self?.updateKeyboardOverlap()
                self?.applyAll()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateKeyboardOverlap()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            updateKeyboardOverlap()
        }

        private func installObservers() {
            let nc = NotificationCenter.default
            let names: [Notification.Name] = [
                UIResponder.keyboardWillChangeFrameNotification,
                UIResponder.keyboardWillShowNotification,
                UIResponder.keyboardDidShowNotification,
                UIResponder.keyboardWillHideNotification,
                UIResponder.keyboardDidHideNotification,
                UIDevice.orientationDidChangeNotification,
                UIWindow.didBecomeKeyNotification,
            ]
            for name in names {
                observers.append(nc.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    self?.updateKeyboardOverlap(from: notification)
                    self?.applyAll()
                    DispatchQueue.main.async {
                        self?.updateKeyboardOverlap()
                        self?.applyAll()
                    }
                })
            }
        }

        private func uninstallObservers() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
        }

        private func applyAll() {
            applyHostingKeyboardIgnore()
            pinPresentationRootToWindow()
        }

        private func applyHostingKeyboardIgnore() {
            var r: UIResponder? = self
            while let cur = r {
                if let vc = cur as? UIViewController {
                    stripKeyboardSafeArea(from: vc)
                }
                r = cur.next
            }
            if let root = window?.rootViewController {
                stripKeyboardSafeArea(from: root)
                root.children.forEach(stripKeyboardSafeArea)
                if let presented = root.presentedViewController {
                    stripKeyboardSafeArea(from: presented)
                    presented.children.forEach(stripKeyboardSafeArea)
                }
            }
        }

        private func stripKeyboardSafeArea(from host: UIViewController) {
            if #available(iOS 16.4, *) {
                let name = NSStringFromClass(type(of: host))
                if name.contains("HostingController") {
                    // UIHostingController.safeAreaRegions = .container (exclude keyboard).
                    // Use KVC to avoid the generic Content type parameter.
                    // SafeAreaRegions.container rawValue is 1 on current SDKs.
                    if host.responds(to: NSSelectorFromString("setSafeAreaRegions:")) {
                        host.setValue(1, forKey: "safeAreaRegions")
                    }
                }
            }
            host.additionalSafeAreaInsets = .zero
            host.view.insetsLayoutMarginsFromSafeArea = false
        }

        private func pinPresentationRootToWindow() {
            guard let window else { return }
            // Presentation hosting view + any full-bleed child.
            var targets: [UIView] = []
            if let host = findNearestViewController()?.view {
                targets.append(host)
            }
            if let root = window.rootViewController?.view {
                targets.append(root)
            }
            if let presented = window.rootViewController?.presentedViewController?.view {
                targets.append(presented)
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for target in targets {
                target.transform = .identity
                // Keep full window size so keyboard never leaves a gap / shift.
                if abs(target.bounds.height - window.bounds.height) > 1
                    || abs(target.frame.origin.y) > 1
                    || abs(target.bounds.width - window.bounds.width) > 1 {
                    target.bounds = CGRect(origin: .zero, size: window.bounds.size)
                    target.center = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
                    target.frame = window.bounds
                }
            }
            CATransaction.commit()
        }

        private func updateKeyboardOverlap(from notification: Notification? = nil) {
            guard let window else {
                if reportedKeyboardOverlap != 0 {
                    reportedKeyboardOverlap = 0
                    onKeyboardOverlapChange?(0)
                }
                return
            }
            if notification?.name == UIResponder.keyboardDidHideNotification {
                lastKeyboardFrame = nil
            } else if let value = notification?.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                as? NSValue {
                lastKeyboardFrame = value.cgRectValue
            }

            var overlap: CGFloat = 0
            if lastKeyboardFrame != nil, let hostView = findNearestViewController()?.view {
                let frame = hostView.keyboardLayoutGuide.layoutFrame
                let intersection = hostView.bounds.intersection(frame)
                let touchesBottom = frame.maxY >= hostView.bounds.maxY - 1
                if touchesBottom, !intersection.isNull {
                    overlap = intersection.height
                }
            }
            if overlap <= 0, let lastKeyboardFrame {
                let frame = window.convert(lastKeyboardFrame, from: nil)
                let intersection = window.bounds.intersection(frame)
                let touchesBottom = frame.maxY >= window.bounds.maxY - 1
                overlap = touchesBottom && !intersection.isNull ? intersection.height : 0
            }
            let nextOverlap = max(0, overlap)
            if abs(nextOverlap - reportedKeyboardOverlap) > 0.5 {
                reportedKeyboardOverlap = nextOverlap
                onKeyboardOverlapChange?(nextOverlap)
            }
        }

        private func findNearestViewController() -> UIViewController? {
            var r: UIResponder? = self
            while let cur = r {
                if let vc = cur as? UIViewController { return vc }
                r = cur.next
            }
            return nil
        }
    }
}

extension View {
    /// Keep the session fixed while exposing the keyboard overlap to its canvas.
    func disableKeyboardLayoutShift(keyboardOverlap: Binding<CGFloat>) -> some View {
        background(KeyboardLayoutFixer(keyboardOverlap: keyboardOverlap))
    }
}
