import SwiftUI

struct RemoteSessionView: View {
    @ObservedObject var session: SessionController
    @Binding var isPresented: Bool
    @State private var password = ""
    @State private var toolbarExpanded = true
    @AppStorage("enable_udp_punch") private var enableUdpPunch = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Full-bleed canvas — must remain the primary hit target for mouse/touch.
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
            // Overlays attach only to chrome edges so the canvas keeps receiving taps.
            .overlay(alignment: .top) {
                topBar
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }
            .overlay(alignment: .bottom) {
                Group {
                    if toolbarExpanded {
                        bottomBar
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                    }
                }
            }

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
                    .padding()
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
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

    // MARK: - Toolbar

    private var topBar: some View {
        HStack(spacing: 8) {
            chipButton(icon: "xmark", label: "Close") {
                session.close()
                isPresented = false
            }

            Spacer().allowsHitTesting(false)

            Text(session.statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
                .allowsHitTesting(false)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    toolbarExpanded.toggle()
                }
            } label: {
                Image(systemName: toolbarExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(6)
                    .background(.black.opacity(0.45), in: Circle())
            }
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                chipButton(
                    icon: session.softKeyboardVisible ? "keyboard.chevron.compact.down" : "keyboard",
                    label: session.softKeyboardVisible ? "Hide KB" : "Keyboard"
                ) {
                    let next = !session.softKeyboardVisible
                    if next {
                        session.captureSystemShortcuts = false
                    }
                    session.softKeyboardVisible = next
                }

                chipButton(
                    icon: session.captureSystemShortcuts ? "command.circle.fill" : "command.circle",
                    label: session.captureSystemShortcuts ? "Shortcuts On" : "Shortcuts"
                ) {
                    session.captureSystemShortcuts.toggle()
                }

                chipButton(icon: "doc.on.clipboard", label: "Paste") {
                    session.pasteFromClipboard()
                }

                chipButton(icon: "sparkles.tv", label: session.qualityLabel) {
                    session.cycleQuality()
                }
            }

            HStack(spacing: 8) {
                chipButton(
                    icon: session.viewOnly ? "eye.fill" : "hand.tap",
                    label: session.viewOnly ? "View only" : "Control"
                ) {
                    session.toggleViewOnly()
                }

                chipButton(
                    icon: session.showRemoteCursor ? "cursorarrow.click.2" : "cursorarrow",
                    label: "Cursor"
                ) {
                    session.toggleRemoteCursor()
                }

                punchChip

                Spacer(minLength: 0).allowsHitTesting(false)

                if session.displayWidth > 0 {
                    Text("\(session.displayWidth)×\(session.displayHeight)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.4), in: Capsule())
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(8)
        .background(.ultraThinMaterial.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var punchChip: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(enableUdpPunch ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(enableUdpPunch ? "UDP punch" : "TCP/relay")
                .font(.caption2)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.4), in: Capsule())
        .allowsHitTesting(false)
        .accessibilityLabel(enableUdpPunch ? "UDP hole punch enabled" : "UDP hole punch disabled")
    }

    private func chipButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(label)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.5), in: Capsule())
        }
        .buttonStyle(.plain)
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
