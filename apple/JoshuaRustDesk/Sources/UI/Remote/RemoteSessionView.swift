import SwiftUI

/// Sidecar-inspired remote session: sidebar rail + canvas in HStack (no overlay).
struct RemoteSessionView: View {
    @ObservedObject var session: SessionController
    @Binding var isPresented: Bool
    @State private var password = ""
    @State private var sidebarExpanded = true
    @AppStorage("enable_udp_punch") private var enableUdpPunch = true

    private let sidebarWidth: CGFloat = 56

    var body: some View {
        HStack(spacing: 0) {
            sidecarSidebar
                .frame(width: sidebarWidth)
                .frame(maxHeight: .infinity)
                .background(Color.black.opacity(0.92))

            // Remote canvas occupies remaining space only — never under the sidebar.
            ZStack {
                Color.black

                MetalRemoteView(
                    session: session,
                    onSize: { size in
                        // Soft keyboard floats over the canvas; do not renegotiate
                        // remote viewport size when iOS temporarily shrinks bounds.
                        guard !session.softKeyboardVisible else { return }
                        let s = UIScreen.main.scale
                        session.setViewSize(
                            width: Int(size.width * s),
                            height: Int(size.height * s)
                        )
                    }
                )
                .ignoresSafeArea(.keyboard)

                // Lightweight HUD over canvas only (not over sidebar).
                VStack(alignment: .trailing, spacing: 6) {
                    HStack {
                        Spacer()
                        statusPill
                            .padding(.trailing, 12)
                            .padding(.top, 10)
                    }
                    if session.showQualityHUD, session.phase == .connected {
                        HStack {
                            Spacer()
                            qualityPill
                                .padding(.trailing, 12)
                        }
                    }
                    if !session.lastClipboardNote.isEmpty {
                        HStack {
                            Spacer()
                            Text(session.lastClipboardNote)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.45), in: Capsule())
                                .padding(.trailing, 12)
                                .transition(.opacity)
                        }
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.2), value: session.lastClipboardNote)

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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.keyboard)
        }
        .background(Color.black.ignoresSafeArea())
        // Keyboard must float over remote desktop, not push/resize the canvas.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .statusBarHidden(true)
        .onAppear {
            session.captureSystemShortcuts = true
        }
        .onDisappear {
            session.softKeyboardVisible = false
        }
    }

    // MARK: - Sidecar sidebar (docked rail)

    private var sidecarSidebar: some View {
        VStack(spacing: 6) {
            sidebarIconButton(
                systemName: "xmark",
                label: "Disconnect"
            ) {
                session.close()
                isPresented = false
            }

            Divider().frame(width: 28).overlay(Color.white.opacity(0.2))

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

            Divider().frame(width: 28).overlay(Color.white.opacity(0.2))

            modButton("⌃", active: session.modControl, label: "Control") {
                session.toggleControl()
            }
            modButton("⌥", active: session.modOption, label: "Option") {
                session.toggleOption()
            }
            modButton("⇧", active: session.modShift, label: "Shift") {
                session.toggleShift()
            }
            modButton("⌘", active: session.modCommand, label: "Command") {
                session.toggleCommand()
            }

            if sidebarExpanded {
                Divider().frame(width: 28).overlay(Color.white.opacity(0.2))

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

                sidebarIconButton(
                    systemName: session.isHardDecodeCodec ? "cpu.fill" : "cpu",
                    label: "Codec \(session.codecPreference)"
                ) {
                    session.cycleCodecPreference()
                }

                sidebarIconButton(
                    systemName: session.showQualityHUD ? "chart.bar.fill" : "chart.bar",
                    label: "Quality HUD"
                ) {
                    session.showQualityHUD.toggle()
                }
            }

            Spacer(minLength: 8)

            Circle()
                .fill(connectionDotColor)
                .frame(width: 8, height: 8)
                .padding(.bottom, 2)
                .accessibilityLabel(session.connectionSummary)

            sidebarIconButton(
                systemName: sidebarExpanded ? "chevron.up" : "chevron.down",
                label: sidebarExpanded ? "Collapse" : "Expand"
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    sidebarExpanded.toggle()
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)
        }
    }

    private var connectionDotColor: Color {
        if session.phase != .connected { return .orange.opacity(0.9) }
        if session.connectionDirect { return .green.opacity(0.9) }
        return .yellow.opacity(0.9)
    }

    private func modButton(_ title: String, active: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(active ? Color.black : Color.white.opacity(0.92))
                .frame(width: 40, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? Color.accentColor : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
        .help(label)
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
            if !session.modifiersSummary.isEmpty {
                Text(session.modifiersSummary)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }
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

    private var qualityPill: some View {
        HStack(spacing: 6) {
            Image(systemName: session.connectionDirect ? "bolt.fill" : "arrow.triangle.swap")
                .font(.caption2)
                .foregroundStyle(session.connectionDirect ? .green : .yellow)
            if !session.connectionSummary.isEmpty {
                Text(session.connectionSummary)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            if !session.qualitySummary.isEmpty {
                Text("·")
                    .foregroundStyle(.white.opacity(0.35))
                Text(session.qualitySummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
            }
            if session.isHardDecodeCodec {
                Text("·")
                    .foregroundStyle(.white.opacity(0.35))
                Text("VT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.green)
            } else if !session.qualityCodec.isEmpty {
                Text("·")
                    .foregroundStyle(.white.opacity(0.35))
                Text(session.qualityCodec)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.4), in: Capsule())
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
