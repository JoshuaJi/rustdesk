import SwiftUI

/// Sidecar-inspired remote session: docked rail + canvas.
/// Adapts for iPhone (compact): scrollable rail, compact HUD, safe-area padding.
struct RemoteSessionView: View {
    @ObservedObject var session: SessionController
    @Binding var isPresented: Bool
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    @State private var password = ""
    /// Advanced tools visible in the rail (quality/codec/HUD…).
    @State private var sidebarExpanded = true
    /// Fully hide the rail on compact (edge tab restores it).
    @State private var railHidden = false
    /// Compact overflow tools panel (replaces SwiftUI `Menu`, which is dead under overFullScreen).
    @State private var showToolsPanel = false
    @AppStorage("enable_udp_punch") private var enableUdpPunch = true

    private var isCompact: Bool { hSize == .compact }
    /// Phone landscape: short height — keep advanced tools collapsed.
    private var isShortHeight: Bool { vSize == .compact }

    /// Same rail width as iPad — one clean column of 40pt controls.
    private var sidebarWidth: CGFloat {
        if railHidden { return 0 }
        return 56
    }

    var body: some View {
        GeometryReader { geo in
            let bottomSafe = geo.safeAreaInsets.bottom
            let topSafe = geo.safeAreaInsets.top

            HStack(spacing: 0) {
                if !railHidden {
                    sidecarSidebar(bottomInset: max(bottomSafe, 10), topInset: isCompact ? 8 : max(topSafe, 8))
                        .frame(width: sidebarWidth)
                        .frame(maxHeight: .infinity)
                        .background(Color.black.opacity(0.92))
                }

                // Canvas + HUD. On iPhone: full canvas with floating status.
                ZStack {
                    MetalRemoteView(
                        session: session,
                        onSize: { size in
                            guard !session.softKeyboardVisible else { return }
                            let s = UIScreen.main.scale
                            session.setViewSize(
                                width: Int(size.width * s),
                                height: Int(size.height * s)
                            )
                        }
                    )
                    .padding(.horizontal, isCompact ? 0 : 10)
                    .padding(.bottom, isCompact ? 0 : 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.keyboard)

                    VStack(spacing: 0) {
                        if session.showQualityHUD {
                            if isCompact {
                                HStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    hudPill
                                }
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                            } else {
                                topChromeIPad
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .animation(.easeOut(duration: 0.15), value: session.showQualityHUD)

                    if railHidden {
                        railRevealTab
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }

                    if showToolsPanel {
                        toolsPanelOverlay
                    }

                    if case .needPassword = session.phase {
                        passwordSheet
                    }
                    if case .failed(let msg) = session.phase {
                        failureOverlay(msg)
                    }
                    if session.phase == .connecting {
                        connectingOverlay
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .ignoresSafeArea(.keyboard)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(.keyboard, edges: .all)
        .disableKeyboardLayoutShift()
        .statusBarHidden(true)
        .onAppear {
            // Phone: rail visible, advanced tools in ⋯ panel.
            if isCompact || isShortHeight {
                sidebarExpanded = false
                railHidden = false
                showToolsPanel = false
            }
        }
        .onChange(of: session.softKeyboardVisible) { visible in
            if visible {
                showToolsPanel = false
            }
        }
        .onDisappear {
            session.softKeyboardVisible = false
            showToolsPanel = false
        }
    }

    // MARK: - Top chrome (iPad: reserved strip; iPhone uses floating overlay)

    private var topChromeIPad: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            hudPill
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        // Transparent strip — only the capsule itself is tinted.
        .background(Color.clear)
    }

    private var railRevealTab: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { railHidden = false }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 22, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
        .padding(.leading, 2)
        .accessibilityLabel("Show toolbar")
    }

    // MARK: - Sidecar sidebar (single column, same on phone & iPad)

    private func sidecarSidebar(bottomInset: CGFloat, topInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            sidebarIconButton(systemName: "xmark", label: "Disconnect") {
                session.close()
                isPresented = false
            }
            .padding(.top, topInset)
            .padding(.bottom, 6)

            Divider().frame(width: 28).overlay(Color.white.opacity(0.2))
                .padding(.bottom, 6)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
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
                        // Soft keyboard uses UIKeyInput; HW shortcut capture pauses while it's up
                        // but we no longer clear the preference permanently.
                        session.softKeyboardVisible.toggle()
                    }

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

                    Divider().frame(width: 28).overlay(Color.white.opacity(0.2))

                    if isCompact {
                        // ⋯ opens tappable panel (Menu is dead under overFullScreen).
                        sidebarIconButton(
                            systemName: showToolsPanel ? "ellipsis.circle.fill" : "ellipsis.circle",
                            label: "More tools",
                            emphasized: showToolsPanel
                        ) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                showToolsPanel.toggle()
                            }
                        }
                    } else if sidebarExpanded {
                        advancedToolButtons
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
            }

            VStack(spacing: 6) {
                Circle()
                    .fill(connectionDotColor)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(session.connectionSummary)

                if !isCompact {
                    sidebarIconButton(
                        systemName: sidebarExpanded ? "chevron.up" : "chevron.down",
                        label: sidebarExpanded ? "Collapse" : "Expand"
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            sidebarExpanded.toggle()
                        }
                    }
                } else {
                    sidebarIconButton(
                        systemName: "sidebar.leading",
                        label: "Hide toolbar"
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showToolsPanel = false
                            railHidden = true
                        }
                    }
                }
            }
            .padding(.bottom, bottomInset)
            .padding(.top, 6)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)
        }
    }

    @ViewBuilder
    private var advancedToolButtons: some View {
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
            label: session.showQualityHUD ? "Hide status HUD" : "Show status HUD",
            emphasized: session.showQualityHUD
        ) {
            withAnimation(.easeOut(duration: 0.15)) {
                session.showQualityHUD.toggle()
            }
        }
    }

    /// Floating tools panel — tappable buttons (not UIMenu).
    private var toolsPanelOverlay: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) { showToolsPanel = false }
                }

            VStack(alignment: .leading, spacing: 0) {
                toolsPanelRow(
                    systemName: session.viewOnly ? "eye.fill" : "hand.point.up.left.fill",
                    title: session.viewOnly ? "View only" : "Control mode"
                ) {
                    session.toggleViewOnly()
                }
                toolsPanelRow(
                    systemName: "sparkles.tv",
                    title: "Quality: \(session.qualityLabel)"
                ) {
                    session.cycleQuality()
                }
                toolsPanelRow(
                    systemName: session.isHardDecodeCodec ? "cpu.fill" : "cpu",
                    title: "Codec: \(session.codecPreference)"
                ) {
                    session.cycleCodecPreference()
                }
                toolsPanelRow(
                    systemName: session.showQualityHUD ? "chart.bar.fill" : "chart.bar",
                    title: session.showQualityHUD ? "Hide status HUD" : "Show status HUD"
                ) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        session.showQualityHUD.toggle()
                    }
                }
                if session.hasMultipleDisplays {
                    toolsPanelRow(
                        systemName: "rectangle.on.rectangle",
                        title: "Display \(session.displaySummary)"
                    ) {
                        session.cycleDisplay()
                    }
                }
            }
            .padding(.vertical, 8)
            .frame(width: 260, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            // Anchor just to the right of the 56pt rail.
            .padding(.leading, 64)
            .padding(.top, 56)
            .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
        }
        .transition(.opacity)
        .zIndex(50)
    }

    private func toolsPanelRow(
        systemName: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28)
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var connectionDotColor: Color {
        if session.phase != .connected { return .orange.opacity(0.9) }
        if session.connectionDirect { return .green.opacity(0.95) }
        return .green.opacity(0.55)
    }

    private func modButton(_ title: String, active: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(active ? Color.black : Color.white.opacity(0.92))
                .frame(width: 40, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? Color.white : Color.white.opacity(0.08))
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
                .foregroundStyle(Color.white.opacity(emphasized ? 1.0 : 0.92))
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

    // MARK: - Status HUD ("Cursor · … · Res" — one capsule, snap updates, no morph trail)

    /// Structural identity so quality/clipboard toggles rebuild the whole pill together.
    private var hudStructureKey: String {
        [
            isCompact ? "c" : "r",
            session.showRemoteCursor ? "cur" : "tch",
            session.showQualityHUD ? "q1" : "q0",
            session.lastClipboardNote.isEmpty ? "0" : "1",
            session.modifiersSummary,
            session.phase == .connected ? "on" : "off",
        ].joined(separator: "|")
    }

    private var hudPill: some View {
        HStack(spacing: isCompact ? 5 : 6) {
            Image(systemName: session.connectionDirect ? "bolt.fill" : "arrow.triangle.swap")
                .font(.caption2)
                .foregroundStyle(.white.opacity(session.connectionDirect ? 0.95 : 0.55))

            // Connection / quality metrics (shown whenever the HUD itself is visible).
            if session.phase == .connected {
                if !session.connectionSummary.isEmpty {
                    Text(session.connectionSummary)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                if !session.qualitySummary.isEmpty {
                    Text(session.qualitySummary)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.9))
                }
                if session.isHardDecodeCodec {
                    Text("VT")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                } else if !session.qualityCodec.isEmpty {
                    Text(session.qualityCodec)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                }
                Text("·").foregroundStyle(.white.opacity(0.35))
            }

            Text(session.showRemoteCursor ? "Cursor" : "Touch")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))

            if !session.modifiersSummary.isEmpty {
                Text(session.modifiersSummary)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            }

            // Status line (connection / actions) — never "Res …" (size is next field).
            if !session.statusText.isEmpty,
               !session.statusText.hasPrefix("Res ") {
                Text("·").foregroundStyle(.white.opacity(0.35))
                Text(session.statusText)
                    .font(isCompact ? .caption2.weight(.medium) : .caption.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            // Display size as its own slot.
            if session.displayWidth > 0, session.displayHeight > 0 {
                Text("·").foregroundStyle(.white.opacity(0.35))
                if session.hasMultipleDisplays {
                    Text("D\(session.displaySummary)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white.opacity(0.95))
                }
                Text("\(session.displayWidth)×\(session.displayHeight)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }

            if !session.lastClipboardNote.isEmpty {
                Text("·").foregroundStyle(.white.opacity(0.35))
                Text(session.lastClipboardNote)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, isCompact ? 10 : 12)
        .padding(.vertical, isCompact ? 5 : 7)
        .background(.black.opacity(0.5), in: Capsule())
        // Snap content updates; whole pill show/hide is animated by parent.
        .id(hudStructureKey)
        .transaction { $0.animation = nil }
    }

    // MARK: - Overlays

    private var connectingOverlay: some View {
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
        .padding(.horizontal, 24)
    }

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
                .tint(.white)
                .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(maxWidth: 340)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
    }

    private func failureOverlay(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.white)
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
                .tint(.white)
            }
        }
        .padding(22)
        .frame(maxWidth: 360)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
        .padding()
    }
}
