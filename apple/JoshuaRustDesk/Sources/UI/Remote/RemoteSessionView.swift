import SwiftUI

/// Sidecar-inspired remote session chrome: slim leading sidebar + minimal status.
struct RemoteSessionView: View {
    @ObservedObject var session: SessionController
    @Binding var isPresented: Bool
    @State private var password = ""
    @State private var sidebarExpanded = true
    @AppStorage("enable_udp_punch") private var enableUdpPunch = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MetalRemoteView(
                session: session,
                onSize: { size in
                    let s = UIScreen.main.scale
                    session.setViewSize(
                        width: Int(size.width * s),
                        height: Int(size.height * s)
                    )
                }
            )
            .ignoresSafeArea()

            // Sidecar-style leading sidebar (does not cover the canvas center).
            HStack(spacing: 0) {
                sidecarSidebar
                    .padding(.leading, 8)
                    .padding(.vertical, 12)
                Spacer(minLength: 0).allowsHitTesting(false)
            }
            .allowsHitTesting(true)

            // Top-trailing status pill only.
            VStack {
                HStack {
                    Spacer()
                    statusPill
                        .padding(.trailing, 12)
                        .padding(.top, 10)
                }
                Spacer()
            }
            .allowsHitTesting(false)

            if case .needPassword = session.phase {
                passwordSheet
            }
            if case .failed(let msg) = session.phase {
                failureOverlay(msg)
            }
            if session.phase == .connecting {
                ProgressView("Connecting…")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .allowsHitTesting(false)
            }
        }
        .statusBarHidden(true)
        .onAppear {
            session.captureSystemShortcuts = true
        }
        .onDisappear {
            session.softKeyboardVisible = false
        }
    }

    // MARK: - Sidecar sidebar

    private var sidecarSidebar: some View {
        VStack(spacing: 6) {
            sidebarIconButton(
                systemName: "xmark",
                label: "Disconnect"
            ) {
                session.close()
                isPresented = false
            }

            Divider().frame(width: 28).overlay(Color.white.opacity(0.25))

            sidebarIconButton(
                systemName: session.showRemoteCursor ? "cursorarrow.click.2" : "hand.tap.fill",
                label: session.showRemoteCursor ? "Cursor mode" : "Touch mode",
                emphasized: true
            ) {
                session.toggleRemoteCursor()
            }

            sidebarIconButton(
                systemName: session.softKeyboardVisible ? "keyboard.chevron.compact.down" : "keyboard",
                label: "Keyboard"
            ) {
                let next = !session.softKeyboardVisible
                if next { session.captureSystemShortcuts = false }
                session.softKeyboardVisible = next
            }

            sidebarIconButton(
                systemName: "doc.on.clipboard",
                label: "Paste"
            ) {
                session.pasteFromClipboard()
            }

            if sidebarExpanded {
                Divider().frame(width: 28).overlay(Color.white.opacity(0.25))

                sidebarIconButton(
                    systemName: session.captureSystemShortcuts ? "command.circle.fill" : "command.circle",
                    label: "Shortcuts"
                ) {
                    session.captureSystemShortcuts.toggle()
                }

                sidebarIconButton(
                    systemName: session.viewOnly ? "eye.fill" : "hand.point.up.left.fill",
                    label: session.viewOnly ? "View only" : "Control"
                ) {
                    session.toggleViewOnly()
                }

                sidebarIconButton(
                    systemName: "sparkles.tv",
                    label: session.qualityLabel
                ) {
                    session.cycleQuality()
                }
            }

            Spacer(minLength: 8)

            // Connection indicator
            Circle()
                .fill(enableUdpPunch ? Color.green.opacity(0.9) : Color.orange.opacity(0.9))
                .frame(width: 8, height: 8)
                .padding(.bottom, 2)
                .accessibilityLabel(enableUdpPunch ? "UDP punch on" : "Relay")

            sidebarIconButton(
                systemName: sidebarExpanded ? "chevron.left" : "chevron.right",
                label: sidebarExpanded ? "Collapse" : "Expand"
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    sidebarExpanded.toggle()
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(width: 52)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
    }

    private func sidebarIconButton(
        systemName: String,
        label: String,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(emphasized ? Color.accentColor : Color.white.opacity(0.92))
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(Color.white.opacity(emphasized ? 0.16 : 0.08))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Text(session.showRemoteCursor ? "Cursor" : "Touch")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text("·")
                .foregroundStyle(.white.opacity(0.35))
            Text(session.statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            if session.displayWidth > 0 {
                Text("·")
                    .foregroundStyle(.white.opacity(0.35))
                Text("\(session.displayWidth)×\(session.displayHeight)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.black.opacity(0.45), in: Capsule())
    }

    // MARK: - Overlays

    private var passwordSheet: some View {
        VStack(spacing: 12) {
            Text(session.passwordPrompt.isEmpty ? "Password required" : session.passwordPrompt)
                .foregroundStyle(.white)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            Button("Submit") {
                session.submitPassword(password)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
    }

    private func failureOverlay(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Text("Connection failed")
                .font(.headline)
                .foregroundStyle(.white)
            Text(msg)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
            Button("Close") {
                session.close()
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}
