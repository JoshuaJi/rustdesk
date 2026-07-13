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
    @AppStorage("enable_udp_punch") private var enableUdpPunch = true

    private var isCompact: Bool { hSize == .compact }
    /// Phone landscape: short height — keep advanced tools collapsed.
    private var isShortHeight: Bool { vSize == .compact }

    private var sidebarWidth: CGFloat {
        if railHidden { return 0 }
        return isCompact ? 52 : 56
    }

    var body: some View {
        GeometryReader { geo in
            let leadingSafe = geo.safeAreaInsets.leading
            let trailingSafe = geo.safeAreaInsets.trailing
            let bottomSafe = geo.safeAreaInsets.bottom
            let topSafe = geo.safeAreaInsets.top

            HStack(spacing: 0) {
                if !railHidden {
                    sidecarSidebar(bottomInset: max(bottomSafe, 8), topInset: max(topSafe, 4))
                        .frame(width: sidebarWidth + (isCompact ? leadingSafe : 0))
                        .padding(.leading, isCompact ? leadingSafe : 0)
                        .frame(maxHeight: .infinity)
                        .background(Color.black.opacity(0.92))
                }

                // HUD above desktop (not overlaid on the remote picture).
                ZStack {
                    VStack(spacing: 0) {
                        topChrome
                            .padding(.top, railHidden ? max(topSafe, 4) : 0)

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
                        .padding(.horizontal, isCompact ? 6 : 10)
                        .padding(.bottom, max(isCompact ? 6 : 10, bottomSafe > 0 ? 4 : 0))
                        .padding(.trailing, railHidden && isCompact ? max(trailingSafe, 0) : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(.keyboard)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)

                    if railHidden {
                        railRevealTab
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
                .ignoresSafeArea(.keyboard)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(.keyboard, edges: .all)
        .disableKeyboardLayoutShift()
        .statusBarHidden(!isCompact) // keep status bar on phone for clock/signal
        .onAppear {
            session.captureSystemShortcuts = true
            // Phone: start with advanced tools collapsed; keep primary rail.
            if isCompact || isShortHeight {
                sidebarExpanded = false
            }
        }
        .onChange(of: session.softKeyboardVisible) { visible in
            if visible, isCompact {
                sidebarExpanded = false
            }
        }
        .onChange(of: hSize) { _ in
            if isCompact || isShortHeight {
                sidebarExpanded = false
            }
        }
        .onDisappear {
            session.softKeyboardVisible = false
        }
    }

    // MARK: - Top chrome

    private var topChrome: some View {
        HStack(spacing: 8) {
            if railHidden {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { railHidden = false }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show toolbar")
            }
            Spacer(minLength: 0)
            statusPill
            if !session.lastClipboardNote.isEmpty {
                Text(session.lastClipboardNote)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.45), in: Capsule())
                    .frame(maxWidth: isCompact ? 120 : 200)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, isCompact ? 8 : 12)
        .padding(.vertical, isCompact ? 5 : 8)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .animation(.easeOut(duration: 0.2), value: session.lastClipboardNote)
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

    // MARK: - Sidecar sidebar

    private func sidecarSidebar(bottomInset: CGFloat, topInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Sticky disconnect
            sidebarIconButton(
                systemName: "xmark",
                label: "Disconnect"
            ) {
                session.close()
                isPresented = false
            }
            .padding(.top, max(topInset, 8))
            .padding(.bottom, 4)

            Divider().frame(width: 28).overlay(Color.white.opacity(0.2))
                .padding(.bottom, 4)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: isCompact ? 5 : 6) {
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

                    // Tap → clipboard push; long-press → type as keystrokes.
                    Button {
                        session.pasteFromClipboard()
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: isCompact ? 16 : 17, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .frame(width: hit, height: hit)
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

                    // Modifier keys — 2×2 on compact to save height.
                    if isCompact {
                        VStack(spacing: 5) {
                            HStack(spacing: 4) {
                                modButton("⌃", active: session.modControl, label: "Control") {
                                    session.toggleControl()
                                }
                                modButton("⌥", active: session.modOption, label: "Option") {
                                    session.toggleOption()
                                }
                            }
                            HStack(spacing: 4) {
                                modButton("⇧", active: session.modShift, label: "Shift") {
                                    session.toggleShift()
                                }
                                modButton("⌘", active: session.modCommand, label: "Command") {
                                    session.toggleCommand()
                                }
                            }
                        }
                    } else {
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
                    }

                    if isCompact {
                        // Overflow menu instead of a long expanded list.
                        Menu {
                            advancedMenuItems
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.92))
                                .frame(width: hit, height: hit)
                                .background(Circle().fill(Color.white.opacity(0.08)))
                        }
                        .accessibilityLabel("More tools")
                    } else if sidebarExpanded {
                        Divider().frame(width: 28).overlay(Color.white.opacity(0.2))
                        advancedToolButtons
                    }

                    // Spacer inside scroll so footer still reachable after short content
                    Color.clear.frame(height: 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }

            // Sticky footer: status + collapse / hide rail
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
                }

                if isCompact {
                    sidebarIconButton(
                        systemName: "sidebar.leading",
                        label: "Hide toolbar"
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            railHidden = true
                        }
                    }
                }
            }
            .padding(.bottom, bottomInset)
            .padding(.top, 4)
        }
        .padding(.horizontal, isCompact ? 4 : 6)
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

    @ViewBuilder
    private var advancedMenuItems: some View {
        Button {
            session.captureSystemShortcuts.toggle()
        } label: {
            Label(
                session.captureSystemShortcuts ? "Shortcuts on" : "Shortcuts off",
                systemImage: session.captureSystemShortcuts ? "command.circle.fill" : "command.circle"
            )
        }
        Button {
            session.toggleViewOnly()
        } label: {
            Label(
                session.viewOnly ? "View only" : "Control mode",
                systemImage: session.viewOnly ? "eye.fill" : "hand.point.up.left.fill"
            )
        }
        Button {
            session.cycleQuality()
        } label: {
            Label("Quality: \(session.qualityLabel)", systemImage: "sparkles.tv")
        }
        Button {
            session.cycleCodecPreference()
        } label: {
            Label("Codec: \(session.codecPreference)", systemImage: "cpu")
        }
        Button {
            session.showQualityHUD.toggle()
        } label: {
            Label(
                session.showQualityHUD ? "Hide quality HUD" : "Show quality HUD",
                systemImage: "chart.bar"
            )
        }
        if session.hasMultipleDisplays {
            Button {
                session.cycleDisplay()
            } label: {
                Label("Display \(session.displaySummary)", systemImage: "rectangle.on.rectangle")
            }
        }
    }

    private var hit: CGFloat { isCompact ? 44 : 40 }

    private var connectionDotColor: Color {
        if session.phase != .connected { return .orange.opacity(0.9) }
        if session.connectionDirect { return .green.opacity(0.95) }
        return .green.opacity(0.55)
    }

    private func modButton(_ title: String, active: Bool, label: String, action: @escaping () -> Void) -> some View {
        let w: CGFloat = isCompact ? 22 : 40
        let h: CGFloat = isCompact ? 32 : 40
        return Button(action: action) {
            Text(title)
                .font(.system(size: isCompact ? 12 : 15, weight: .bold, design: .rounded))
                .foregroundStyle(active ? Color.black : Color.white.opacity(0.92))
                .frame(width: w, height: h)
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
                .font(.system(size: isCompact ? 16 : 17, weight: .semibold))
                .foregroundStyle(Color.white.opacity(emphasized ? 1.0 : 0.92))
                .frame(width: hit, height: hit)
                .background(
                    Circle()
                        .fill(Color.white.opacity(emphasized ? 0.16 : 0.08))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    // MARK: - Status pill

    private var statusPill: some View {
        Group {
            if isCompact {
                compactStatusPill
            } else {
                fullStatusPill
            }
        }
        .padding(.horizontal, isCompact ? 10 : 12)
        .padding(.vertical, isCompact ? 5 : 7)
        .background(.black.opacity(0.45), in: Capsule())
    }

    private var compactStatusPill: some View {
        HStack(spacing: 5) {
            Image(systemName: session.connectionDirect ? "bolt.fill" : "arrow.triangle.swap")
                .font(.caption2)
                .foregroundStyle(.white.opacity(session.connectionDirect ? 0.95 : 0.55))
            Text(session.showRemoteCursor ? "Cursor" : "Touch")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
            if !session.modifiersSummary.isEmpty {
                Text(session.modifiersSummary)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            }
            Text("·")
                .foregroundStyle(.white.opacity(0.35))
            Text(session.statusText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var fullStatusPill: some View {
        HStack(spacing: 6) {
            if session.showQualityHUD, session.phase == .connected {
                qualityHUDPrefix
                Text("·")
                    .foregroundStyle(.white.opacity(0.35))
            }
            Text(session.showRemoteCursor ? "Cursor" : "Touch")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            if !session.modifiersSummary.isEmpty {
                Text(session.modifiersSummary)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
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
                        .foregroundStyle(.white.opacity(0.95))
                }
                Text("\(session.displayWidth)×\(session.displayHeight)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    @ViewBuilder
    private var qualityHUDPrefix: some View {
        HStack(spacing: 5) {
            Image(systemName: session.connectionDirect ? "bolt.fill" : "arrow.triangle.swap")
                .font(.caption2)
                .foregroundStyle(.white.opacity(session.connectionDirect ? 0.95 : 0.55))
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
        }
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
