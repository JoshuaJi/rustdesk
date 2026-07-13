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
                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                        Text(session.connectionStage.isEmpty ? "Connecting…" : session.connectionStage)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        if !session.peerId.isEmpty {
                            Text(session.peerId)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        Button("Cancel") {
                            session.close()
                            isPresented = false
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .padding(.top, 4)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.keyboard)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        // SwiftUI-level ignore (not sufficient alone for fullScreenCover).
        .ignoresSafeArea(.keyboard, edges: .all)
        // UIKit-level: strip hosting-controller keyboard safe area + re-pin frame.
        .disableKeyboardLayoutShift()
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

            // Tap → true clipboard push; long-press → type as keystrokes.
            Button {
                session.pasteFromClipboard()
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    session.typeClipboardAsKeystrokes()
                }
            )
            .accessibilityLabel("Paste clipboard to peer")
            .help("Tap: push clipboard · Long-press: type keystrokes")

            if session.hasMultipleDisplays {
                sidebarIconButton(
                    systemName: "rectangle.on.rectangle",
                    label: "Display \(session.displaySummary)",
                    emphasized: true
                ) {
                    session.cycleDisplay()
                }
            }

            sidebarIconButton(
                systemName: session.audioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: session.audioMuted ? "Unmute audio" : "Mute audio",
                emphasized: !session.audioMuted
            ) {
                session.toggleAudioMuted()
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
                if session.hasMultipleDisplays {
                    Text("D\(session.displaySummary)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.accentColor.opacity(0.95))
                }
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
            Text("·")
                .foregroundStyle(.white.opacity(0.35))
            let aud = RemoteAudioPlayer.shared
            let label: String = {
                if session.audioMuted { return "MUTE" }
                if aud.framesReceived > 0 {
                    // Peak tip: 0.00 ≈ silent decode; >0.01 ≈ real signal.
                    return aud.lastPeak > 0.01 ? "AUD" : "AUD₀"
                }
                return "…"
            }()
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(
                    session.audioMuted
                        ? .orange
                        : (aud.framesReceived > 0
                            ? (aud.lastPeak > 0.01 ? .green : .yellow)
                            : .white.opacity(0.5))
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.4), in: Capsule())
    }

    // MARK: - Overlays

    private var passwordSheet: some View {
        VStack(spacing: 12) {
            Text(session.passwordPrompt.isEmpty ? "Password required" : session.passwordPrompt)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .submitLabel(.go)
                .onSubmit {
                    session.submitPassword(password)
                }
            HStack(spacing: 12) {
                Button("Cancel") {
                    session.close()
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .tint(.white)
                Button("Submit") {
                    session.submitPassword(password)
                }
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
    }

    private func failureOverlay(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Connection failed")
                .font(.headline)
                .foregroundStyle(.white)
            Text(msg)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Close") {
                    session.close()
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .tint(.white)
                Button("Retry") {
                    session.reconnect()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(maxWidth: 360)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
        .padding()
    }
}
