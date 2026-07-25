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
    /// Compact overflow tools panel (the modal host needs directly tappable controls).
    @State private var showToolsPanel = false
    /// Bottom-anchored system keyboard overlap reported by the UIKit layout bridge.
    @State private var keyboardOverlap: CGFloat = 0
    @State private var remoteScreenLocked = false
    @State private var isAuthenticatingUnlock = false
    @State private var showLockPasswordPrompt = false
    @State private var lockPassword = ""
    @State private var lockStatusMessage = ""
    @AppStorage("enable_udp_punch") private var enableUdpPunch = true

    private let lockCredentialStore = RemoteLockCredentialStore.shared

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
            let isPortrait = geo.size.height >= geo.size.width

            Group {
                if isPortrait {
                    portraitLayout(bottomInset: bottomSafe, topInset: topSafe)
                } else {
                    ZStack(alignment: .leading) {
                        remoteCanvas(isPortrait: false, showsRailReveal: true)
                            .padding(.bottom, keyboardOverlap)

                        if !railHidden {
                            sidecarSidebar(
                                bottomInset: max(bottomSafe, 10),
                                topInset: isCompact ? 8 : max(topSafe, 8)
                            )
                            .frame(width: sidebarWidth)
                            .frame(maxHeight: .infinity)
                            .padding(.bottom, keyboardOverlap)
                            .opacity(showToolsPanel ? 0 : 1)
                            .allowsHitTesting(!showToolsPanel)
                        }
                    }
                }
            }
            .onAppear {
                showKeyboardWhenReady(isPortrait: isPortrait, phase: session.phase)
            }
            .onChange(of: isPortrait) { portrait in
                showKeyboardWhenReady(isPortrait: portrait, phase: session.phase)
            }
            .onChange(of: session.phase) { phase in
                showKeyboardWhenReady(isPortrait: isPortrait, phase: phase)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .all)
        .ignoresSafeArea(.keyboard, edges: .all)
        .disableKeyboardLayoutShift(keyboardOverlap: $keyboardOverlap)
        .statusBarHidden(true)
        .alert("Remote computer login password", isPresented: $showLockPasswordPrompt) {
            SecureField("Computer account password", text: $lockPassword)
                // Avoid iCloud Keychain autofilling the Portico/RustDesk *connection* password.
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {
                lockPassword = ""
                // Only restore keyboard if we are not mid-unlock.
                if !session.isSubmittingOsPassword {
                    restorePortraitKeyboard()
                }
            }
            Button("Unlock once") {
                unlockOnceWithoutSaving()
            }
            .disabled(lockPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Save & Unlock") {
                saveLockPasswordAndUnlock()
            }
            .disabled(lockPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(
                "Enter the Windows/macOS user-account password for this computer (what you type at its lock screen)—not the Portico connection password. Prefer typing it manually; do not accept iCloud autofill."
            )
        }
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

    private func portraitLayout(bottomInset: CGFloat, topInset: CGFloat) -> some View {
        ZStack {
            remoteCanvas(isPortrait: true, showsRailReveal: false)
            portraitTopBar(topInset: topInset)
                .frame(maxHeight: .infinity, alignment: .top)
                .opacity(showToolsPanel ? 0 : 1)
                .allowsHitTesting(!showToolsPanel)
            portraitControlBar(
                bottomInset: keyboardOverlap > 0 ? 8 : max(bottomInset, 8)
            )
            .frame(maxHeight: .infinity, alignment: .bottom)
            .opacity(showToolsPanel ? 0 : 1)
            .allowsHitTesting(!showToolsPanel)
        }
        .padding(.bottom, keyboardOverlap)
    }

    private func remoteCanvas(isPortrait: Bool, showsRailReveal: Bool) -> some View {
        ZStack {
            MetalRemoteView(
                session: session,
                onSize: { size in
                    let scale = UIScreen.main.scale
                    session.setViewSize(
                        width: Int(size.width * scale),
                        height: Int(size.height * scale)
                    )
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.keyboard)

            VStack(spacing: 0) {
                if session.showQualityHUD {
                    if isCompact || isPortrait {
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

            if showsRailReveal, railHidden {
                railRevealTab
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }

            if showToolsPanel {
                toolsPanelOverlay
            }

            if case .needPassword = session.phase {
                passwordSheet
            }
            if case .failed(let message) = session.phase {
                failureOverlay(message)
            }
            if session.phase == .connecting {
                connectingOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .ignoresSafeArea(.keyboard)
    }

    private func showKeyboardWhenReady(isPortrait: Bool, phase: SessionPhase) {
        if isPortrait, phase == .connected {
            session.softKeyboardVisible = true
        }
    }

    // MARK: - Portrait controls

    private func portraitTopBar(topInset: CGFloat) -> some View {
        HStack(spacing: 12) {
            portraitKeyButton(title: "esc", label: "Escape") {
                session.sendEscape()
            }
            .disabled(session.phase != .connected || session.viewOnly)

            Spacer(minLength: 0)

            if !lockStatusMessage.isEmpty {
                Text(lockStatusMessage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer(minLength: 0)

            portraitKeyButton(
                systemName: isAuthenticatingUnlock ? "ellipsis" : "power",
                label: remoteScreenLocked ? "Unlock remote screen" : "Lock remote screen",
                emphasized: remoteScreenLocked
            ) {
                handleRemotePowerButton()
            }
            .disabled(
                session.phase != .connected
                    || session.viewOnly
                    || isAuthenticatingUnlock
            )
            .contextMenu {
                Button("Unlock with computer login password") {
                    remoteScreenLocked = true
                    unlockUsingSavedPassword()
                }
                Button("Replace computer login password") {
                    replaceLockPassword()
                }
            }
        }
        .padding(.horizontal, 12)
        // Use the notch/status safe-area height for essential controls instead
        // of reserving another full control row beneath it.
        .frame(height: max(topInset, 52), alignment: .bottom)
        .accessibilityLabel("Connected to \(session.peerId)")
    }

    private func portraitControlBar(bottomInset: CGFloat) -> some View {
        HStack(spacing: 6) {
            disconnectControl
            inputControlButtons
            moreToolsControl
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        .padding(.horizontal, 8)
        .padding(.bottom, bottomInset)
        .frame(maxWidth: .infinity, alignment: .center)
        .shadow(color: .black.opacity(0.42), radius: 12, y: 5)
    }

    private func portraitKeyButton(
        title: String? = nil,
        systemName: String? = nil,
        label: String,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 17, weight: .bold))
                } else {
                    Text(title ?? "")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(emphasized ? Color.black : Color.white)
            .frame(width: 44, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(emphasized ? Color.white : Color.black.opacity(0.62))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private func handleRemotePowerButton() {
        if remoteScreenLocked {
            unlockUsingSavedPassword()
        } else {
            session.lockRemoteScreen()
            remoteScreenLocked = true
            lockStatusMessage = "Remote screen locked"
        }
    }

    private func unlockUsingSavedPassword() {
        guard !isAuthenticatingUnlock else { return }
        isAuthenticatingUnlock = true
        lockStatusMessage = "Authenticating…"
        lockCredentialStore.retrieve(
            for: session.peerId,
            reason: "Use the saved computer login password for \(session.peerId)"
        ) { result in
            switch result {
            case .success(let savedPassword):
                submitRemoteUnlock(password: savedPassword)
            case .failure(let error):
                isAuthenticatingUnlock = false
                if let credentialError = error as? RemoteLockCredentialError,
                   case .notFound = credentialError {
                    lockStatusMessage = "Enter computer login password"
                    presentLockPasswordPrompt()
                } else {
                    lockStatusMessage = error.localizedDescription
                }
            }
        }
    }

    private func saveLockPasswordAndUnlock() {
        let enteredPassword = lockPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        lockPassword = ""
        guard !enteredPassword.isEmpty else { return }

        isAuthenticatingUnlock = true
        lockStatusMessage = "Authenticating…"
        // Keep soft keyboard down so SecureField text cannot re-inject into the peer.
        session.softKeyboardVisible = false
        lockCredentialStore.authenticate(
            reason: "Protect the computer login password for \(session.peerId)"
        ) {
            result in
            switch result {
            case .success(let context):
                do {
                    try lockCredentialStore.save(
                        password: enteredPassword,
                        for: session.peerId,
                        context: context
                    )
                    submitRemoteUnlock(password: enteredPassword)
                } catch {
                    isAuthenticatingUnlock = false
                    lockStatusMessage = error.localizedDescription
                }
            case .failure(let error):
                isAuthenticatingUnlock = false
                lockStatusMessage = error.localizedDescription
            }
        }
    }

    /// Type the password once without writing Keychain — useful when debugging a rejected unlock.
    private func unlockOnceWithoutSaving() {
        let enteredPassword = lockPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        lockPassword = ""
        guard !enteredPassword.isEmpty else { return }
        session.softKeyboardVisible = false
        submitRemoteUnlock(password: enteredPassword)
    }

    private func submitRemoteUnlock(password: String) {
        // Soft keyboard stays off for the full OS-password sequence (see SessionController).
        session.softKeyboardVisible = false
        session.unlockRemoteScreen(using: password)
        isAuthenticatingUnlock = false
        // Stay in locked mode so a wrong password can be retried via the power button
        // without an extra lock. If still locked after the attempt, long-press → Unlock.
        lockStatusMessage = "Unlocking…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            remoteScreenLocked = false
            if lockStatusMessage == "Unlocking…" {
                lockStatusMessage = "Unlock submitted — tap power again if still locked"
            }
            // Restore soft keyboard only after unlock keystrokes are fully done.
            if !session.isSubmittingOsPassword {
                restorePortraitKeyboard()
            }
        }
    }

    private func replaceLockPassword() {
        lockCredentialStore.remove(for: session.peerId)
        lockPassword = ""
        lockStatusMessage = "Enter new computer login password"
        presentLockPasswordPrompt()
    }

    private func presentLockPasswordPrompt() {
        // Release the pass-through keyboard window so the alert's SecureField can focus.
        session.softKeyboardVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            showLockPasswordPrompt = true
        }
    }

    private func restorePortraitKeyboard() {
        if session.phase == .connected {
            session.softKeyboardVisible = true
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
            disconnectControl
            .padding(.top, topInset)
            .padding(.bottom, 6)

            Divider().frame(width: 28).overlay(Color.white.opacity(0.2))
                .padding(.bottom, 6)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    inputControlButtons

                    Divider().frame(width: 28).overlay(Color.white.opacity(0.2))

                    modifierControlButtons

                    Divider().frame(width: 28).overlay(Color.white.opacity(0.2))

                    if isCompact {
                        // ⋯ opens a directly tappable panel inside the modal host.
                        moreToolsControl
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
    }

    private var disconnectControl: some View {
        sidebarIconButton(systemName: "xmark", label: "Disconnect") {
            session.close()
            isPresented = false
        }
    }

    @ViewBuilder
    private var inputControlButtons: some View {
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
            session.softKeyboardVisible.toggle()
        }

        clipboardControl

        if session.hasMultipleDisplays {
            sidebarIconButton(
                systemName: "rectangle.on.rectangle",
                label: "Display \(session.displaySummary)",
                emphasized: true
            ) {
                session.cycleDisplay()
            }
        }
    }

    private var clipboardControl: some View {
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
    }

    @ViewBuilder
    private var modifierControlButtons: some View {
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

    private var moreToolsControl: some View {
        sidebarIconButton(
            systemName: showToolsPanel ? "ellipsis.circle.fill" : "ellipsis.circle",
            label: "More tools",
            emphasized: showToolsPanel
        ) {
            withAnimation(.easeOut(duration: 0.15)) {
                showToolsPanel.toggle()
            }
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
                session.toggleQualityHUD()
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("Keyboard modifiers")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    HStack(spacing: 8) {
                        modifierControlButtons
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider().overlay(Color.white.opacity(0.12))

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
                        session.toggleQualityHUD()
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
