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
    /// When true, portrait/side control bar shows tools (chevron on left);
    /// when false, shows keys: tab + modifiers (chevron on right).
    @State private var controlBarShowsTools = false
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
                        remoteCanvas(
                            isPortrait: false,
                            showsRailReveal: true,
                            topSafe: topSafe
                        )
                            .padding(.bottom, keyboardOverlap)

                        if !railHidden {
                            sidecarSidebar(
                                bottomInset: max(bottomSafe, 10),
                                // Keep rail below Dynamic Island / status region on phones.
                                topInset: max(topSafe, isCompact ? 12 : 8)
                            )
                            .frame(width: sidebarWidth)
                            .frame(maxHeight: .infinity)
                            .padding(.bottom, keyboardOverlap)
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
                controlBarShowsTools = false
            }
        }
        .onChange(of: session.softKeyboardVisible) { visible in
            if visible {
                controlBarShowsTools = false
            }
        }
        .onChange(of: session.phase) { phase in
            if case .closed = phase {
                isPresented = false
            }
        }
        .onDisappear {
            session.softKeyboardVisible = false
            controlBarShowsTools = false
        }
    }

    private func portraitLayout(bottomInset: CGFloat, topInset: CGFloat) -> some View {
        ZStack {
            remoteCanvas(isPortrait: true, showsRailReveal: false, topSafe: topInset)
            portraitTopBar(topInset: topInset)
                .frame(maxHeight: .infinity, alignment: .top)
            portraitControlBar(
                bottomInset: keyboardOverlap > 0 ? 8 : max(bottomInset, 8)
            )
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .padding(.bottom, keyboardOverlap)
    }

    /// Top padding so the quality HUD clears Dynamic Island / notch.
    /// Portrait also clears the esc/power strip that lives in the top safe band.
    private func hudTopInset(isPortrait: Bool, topSafe: CGFloat) -> CGFloat {
        if isPortrait {
            return max(topSafe, 52) + 6
        }
        return max(topSafe, 12) + 6
    }

    private func remoteCanvas(
        isPortrait: Bool,
        showsRailReveal: Bool,
        topSafe: CGFloat
    ) -> some View {
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
                        .padding(.top, hudTopInset(isPortrait: isPortrait, topSafe: topSafe))
                        .allowsHitTesting(false)
                    } else {
                        topChromeIPad
                            .padding(.top, max(topSafe, 8))
                    }
                }
                Spacer(minLength: 0)
            }
            .animation(.easeOut(duration: 0.15), value: session.showQualityHUD)

            if showsRailReveal, railHidden {
                railRevealTab
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }

            if case .needPassword = session.phase {
                passwordSheet
            }
            // Recoverable drops stay in `.connecting` and auto-reconnect — no timeout wall.
            // Only non-recoverable auth/config errors use a failure sheet.
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
            portraitKeyButton(
                title: "esc",
                label: "Escape",
                outerCorner: .topLeading
            ) {
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
                emphasized: remoteScreenLocked,
                outerCorner: .topTrailing
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
            if controlBarShowsTools {
                // Tools mode: chevron leftmost (points right to return to keys)
                controlBarChevron(pointsLeading: false)

                controlBarZoneDivider

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        toolZoneButtons
                    }
                }
            } else {
                // Keys mode: tab | modifiers | chevron (points left to open tools)
                keyZoneControls

                controlBarZoneDivider

                controlBarChevron(pointsLeading: true)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        .padding(.horizontal, 8)
        .padding(.bottom, bottomInset)
        .frame(maxWidth: .infinity, alignment: .center)
        .shadow(color: .black.opacity(0.42), radius: 12, y: 5)
        .animation(.easeInOut(duration: 0.2), value: controlBarShowsTools)
    }

    private var controlBarZoneDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.18))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 2)
    }

    /// Left chevron = open tools (on right of keys). Right chevron = back to keys (on left of tools).
    private func controlBarChevron(pointsLeading: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                controlBarShowsTools = pointsLeading
            }
        } label: {
            Image(systemName: pointsLeading ? "chevron.left" : "chevron.right")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pointsLeading ? "Show tools" : "Show keys")
        .help(pointsLeading ? "Show tools" : "Show keys")
    }

    /// Device display corner radius (matches the physical screen bezel curve).
    private var screenCornerRadius: CGFloat {
        let screen = UIScreen.main
        // KVC used for layout that should match the display contour.
        if let radius = screen.value(forKey: "displayCornerRadius") as? CGFloat, radius > 0 {
            return radius
        }
        if let radius = screen.value(forKey: "_displayCornerRadius") as? CGFloat, radius > 0 {
            return radius
        }
        // Fallback: modern iPhone continuous corner is large relative to control size.
        return 44
    }

    /// Which corner of a top chrome button sits against the device bezel.
    private enum TopChromeOuterCorner {
        case topLeading
        case topTrailing
    }

    private func portraitKeyButton(
        title: String? = nil,
        systemName: String? = nil,
        label: String,
        emphasized: Bool = false,
        outerCorner: TopChromeOuterCorner? = nil,
        action: @escaping () -> Void
    ) -> some View {
        // Only the outer corner uses the screen radius; inner corners stay compact.
        let inner: CGFloat = 11
        let outer = screenCornerRadius
        let shape = UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: outerCorner == .topLeading ? outer : inner,
                bottomLeading: inner,
                bottomTrailing: inner,
                topTrailing: outerCorner == .topTrailing ? outer : inner
            ),
            style: .continuous
        )
        return Button(action: action) {
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
                shape
                    .fill(emphasized ? Color.white : Color.black.opacity(0.62))
                    .overlay(
                        shape.stroke(Color.white.opacity(0.16), lineWidth: 1)
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
            if controlBarShowsTools {
                // Tools mode: chevron at top (points to keys / down-right metaphor = chevron.right)
                controlBarChevron(pointsLeading: false)
                    .padding(.top, topInset)
                    .padding(.bottom, 6)

                Divider().frame(width: 28).overlay(Color.white.opacity(0.2))
                    .padding(.bottom, 6)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        toolZoneButtons
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                }
            } else {
                // Keys mode: tab, divider, modifiers, then chevron to tools
                VStack(spacing: 6) {
                    controlBarTextButton(title: "tab", label: "Tab") {
                        session.sendTab()
                    }
                    .disabled(session.phase != .connected || session.viewOnly)

                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 22, height: 1)
                        .padding(.vertical, 2)

                    modifierControlButtons

                    controlBarChevron(pointsLeading: true)
                }
                .padding(.top, topInset)
                .padding(.bottom, 6)

                Spacer(minLength: 0)
            }

            VStack(spacing: 6) {
                Circle()
                    .fill(connectionDotColor)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(session.connectionSummary)

                sidebarIconButton(
                    systemName: "sidebar.leading",
                    label: "Hide toolbar"
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        controlBarShowsTools = false
                        railHidden = true
                    }
                }
            }
            .padding(.bottom, bottomInset)
            .padding(.top, 6)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.2), value: controlBarShowsTools)
    }

    private var disconnectControl: some View {
        sidebarIconButton(systemName: "xmark", label: "Disconnect") {
            session.close()
            isPresented = false
        }
    }

    /// Keys zone: Tab (leftmost) | sticky modifiers.
    @ViewBuilder
    private var keyZoneControls: some View {
        controlBarTextButton(title: "tab", label: "Tab") {
            session.sendTab()
        }
        .disabled(session.phase != .connected || session.viewOnly)

        controlBarZoneDivider

        modifierControlButtons
    }

    @ViewBuilder
    private var modifierControlButtons: some View {
        modButton("⌃", active: session.modControl, label: "Control") {
            session.toggleControl()
        }
        .disabled(session.phase != .connected || session.viewOnly)
        modButton("⌥", active: session.modOption, label: "Option") {
            session.toggleOption()
        }
        .disabled(session.phase != .connected || session.viewOnly)
        modButton("⇧", active: session.modShift, label: "Shift") {
            session.toggleShift()
        }
        .disabled(session.phase != .connected || session.viewOnly)
        modButton("⌘", active: session.modCommand, label: "Command") {
            session.toggleCommand()
        }
        .disabled(session.phase != .connected || session.viewOnly)
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

    /// Tools zone icons for the expanded iPad rail.
    @ViewBuilder
    private var toolZoneButtons: some View {
        disconnectControl
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

    /// Compact text key (tab, etc.) matching the circular control-bar chrome.
    private func controlBarTextButton(
        title: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.white.opacity(0.08)))
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
            if !session.lastError.isEmpty,
               session.connectionStage.localizedCaseInsensitiveContains("reconnect")
                || session.statusText.localizedCaseInsensitiveContains("retry") {
                Text(session.lastError)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
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

    /// Shown only for non-recoverable errors (wrong password, access denied, …).
    private func failureOverlay(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.white)
            Text("Can't connect")
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
                Button("Try again") {
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
