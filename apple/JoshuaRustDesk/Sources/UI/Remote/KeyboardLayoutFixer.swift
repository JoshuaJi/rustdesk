import SwiftUI
import UIKit

/// Prevents the system keyboard from resizing the remote-session layout.
/// Attached as a zero-size background view via `disableKeyboardLayoutShift()`.
///
/// SwiftUI `.ignoresSafeArea(.keyboard)` alone is not enough inside
/// `fullScreenCover` — UIKit still applies keyboard safe-area insets to the
/// hosting controller. We strip those and re-pin the presentation root to the
/// full window bounds when the keyboard appears.
struct KeyboardLayoutFixer: UIViewRepresentable {
    func makeUIView(context: Context) -> FixerView {
        FixerView()
    }

    func updateUIView(_ uiView: FixerView, context: Context) {}

    final class FixerView: UIView {
        private var observers: [NSObjectProtocol] = []

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
            guard window != nil else { return }
            applyAll()
            installObservers()
            DispatchQueue.main.async { [weak self] in
                self?.applyAll()
            }
        }

        private func installObservers() {
            let nc = NotificationCenter.default
            let names: [Notification.Name] = [
                UIResponder.keyboardWillChangeFrameNotification,
                UIResponder.keyboardWillShowNotification,
                UIResponder.keyboardDidShowNotification,
                UIResponder.keyboardWillHideNotification,
                UIResponder.keyboardDidHideNotification,
            ]
            for name in names {
                observers.append(nc.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.applyAll()
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
    /// Soft keyboard floats without shifting remote session UI.
    func disableKeyboardLayoutShift() -> some View {
        background(KeyboardLayoutFixer())
    }
}
