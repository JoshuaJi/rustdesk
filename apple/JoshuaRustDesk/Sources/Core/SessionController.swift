import Foundation
import Combine
import UIKit

enum SessionPhase: Equatable {
    case idle
    case connecting
    case needPassword
    case connected
    case failed(String)
    case closed
}

/// One remote monitor advertised by the peer.
struct RemoteDisplayInfo: Identifiable, Equatable {
    /// 0-based index used by the session / soft RGBA buffer.
    let id: Int
    var width: Int
    var height: Int
    var x: Int
    var y: Int
    var cursorEmbedded: Bool

    var label: String {
        if width > 0, height > 0 {
            return "Display \(id + 1) · \(width)×\(height)"
        }
        return "Display \(id + 1)"
    }
}

/// Owns one remote session: events from Rust, frame notifications, login, input.
final class SessionController: ObservableObject {
    @Published var phase: SessionPhase = .idle
    @Published var statusText: String = ""
    @Published var passwordPrompt: String = ""
    @Published var peerId: String = ""
    @Published var frameTick: UInt64 = 0
    @Published var displayWidth: Int = 0
    @Published var displayHeight: Int = 0
    /// All peer monitors (empty until peer_info).
    @Published var displays: [RemoteDisplayInfo] = []
    /// Currently captured / shown display index.
    @Published var currentDisplayIndex: Int = 0
    /// Soft-keyboard toggle (bound by toolbar / Metal view).
    @Published var softKeyboardVisible: Bool = false
    /// Steal iPadOS system shortcuts (⌘C etc.) when possible.
    @Published var captureSystemShortcuts: Bool = true
    /// Simple quality label for toolbar.
    @Published var qualityLabel: String = "Balanced"
    @Published var viewOnly: Bool = false
    @Published var showRemoteCursor: Bool = true
    /// When true, remote desktop audio is muted (`disable-audio` on).
    @Published var audioMuted: Bool = false
    /// Remote peer cursor (display coords) + image for overlay.
    @Published private(set) var cursorX: CGFloat = 0
    @Published private(set) var cursorY: CGFloat = 0
    @Published private(set) var cursorHotX: CGFloat = 0
    @Published private(set) var cursorHotY: CGFloat = 0
    @Published private(set) var cursorImage: UIImage?
    @Published private(set) var cursorVisible: Bool = false
    /// When peer embeds cursor in the video stream, hide our overlay.
    @Published private(set) var cursorEmbedded: Bool = false

    // MARK: Sidecar sticky modifiers
    @Published var modCommand = false
    @Published var modOption = false
    @Published var modControl = false
    @Published var modShift = false

    // MARK: Connection / quality HUD
    @Published var connectionSecure = false
    @Published var connectionDirect = false
    @Published var streamType = ""
    @Published var qualitySpeed = ""
    @Published var qualityFPS = ""
    @Published var qualityDelay = ""
    @Published var qualityCodec = ""
    @Published var showQualityHUD = true
    @Published var lastClipboardNote = ""
    /// Preferred codec for host negotiate: auto / h264 / h265.
    @Published var codecPreference: String = UserDefaults.standard.string(forKey: "codec_preference") ?? "h264"
    /// When true, iOS pasteboard changes are pushed to the peer automatically.
    @Published var autoSyncClipboard: Bool = true
    /// Last hard failure message (also mirrored into `.failed`).
    @Published private(set) var lastError: String = ""
    /// Human-readable connection stage for HUD / home status.
    @Published private(set) var connectionStage: String = ""

    private(set) var sessionUUID: String = ""
    private var active = false
    private var lastPassword: String = ""
    private var lastForceRelay = false
    private var rememberPassword = false
    private var cursorCache: [String: (image: UIImage, hotx: CGFloat, hoty: CGFloat)] = [:]
    private var currentCursorId: String = ""
    /// Only auto-disable view-only once per connection (don't fight user's toggle).
    private var didEnsureControlMode = false
    /// Only force-enable audio once per connection (don't fight mute).
    private var didEnsureAudio = false
    /// Last canvas size reported by Metal view (points × scale).
    private var lastViewW = 0
    private var lastViewH = 0
    /// Last resolution we asked the host to use.
    private var lastRequestedResW = 0
    private var lastRequestedResH = 0
    private var resolutionWork: DispatchWorkItem?
    /// Last text we wrote to / read from pasteboard for loop suppression.
    private var lastPushedClipboard: String = ""
    private var lastReceivedClipboard: String = ""
    private var pasteboardObserver: NSObjectProtocol?
    private var connectTimeoutWork: DispatchWorkItem?
    /// Seconds to wait for peer_info / frames before failing.
    private let connectTimeoutSeconds: TimeInterval = 45

    // Strong ref so C callback can recover self
    private var retainedSelf: Unmanaged<SessionController>?

    deinit {
        stopPasteboardObserver()
        close()
    }

    func connect(peerId: String, password: String, forceRelay: Bool = false, rememberPassword: Bool = false) {
        close()
        self.peerId = peerId
        self.lastPassword = password
        self.lastForceRelay = forceRelay
        self.rememberPassword = rememberPassword
        sessionUUID = UUID().uuidString
        phase = .connecting
        lastError = ""
        setStage("Looking up \(peerId)…")
        softKeyboardVisible = false
        viewOnly = false
        audioMuted = true
        didEnsureControlMode = false
        didEnsureAudio = false
        lastRequestedResW = 0
        lastRequestedResH = 0
        resolutionWork?.cancel()
        resolutionWork = nil
        clearModifiers(sendKeyUp: false)
        // Audio playback disabled for now (host capture unreliable).
        connectionSecure = false
        connectionDirect = false
        streamType = ""
        qualitySpeed = ""
        qualityFPS = ""
        qualityDelay = ""
        qualityCodec = ""
        lastClipboardNote = ""
        lastPushedClipboard = ""
        lastReceivedClipboard = ""
        displays = []
        currentDisplayIndex = 0
        displayWidth = 0
        displayHeight = 0
        resetCursorState()
        startPasteboardObserver()
        armConnectTimeout()

        RustDeskBridge.shared.pushNetworkOptionsToRust()
        RecentPeersStore.shared.record(
            id: peerId,
            password: password,
            forceRelay: forceRelay,
            rememberPassword: rememberPassword
        )

        var err: UnsafeMutablePointer<CChar>?
        let add = rd_session_add(sessionUUID, peerId, password, forceRelay ? 1 : 0, &err)
        if add != 0 {
            let msg = err.map { String(cString: $0) } ?? "session_add failed"
            if let e = err { rd_free_string(e) }
            fail(msg)
            return
        }
        setStage("Contacting peer…")

        retainedSelf = Unmanaged.passRetained(self)
        let user = retainedSelf!.toOpaque()

        err = nil
        let start = rd_session_start(sessionUUID, peerId, sessionEventTrampoline, user, &err)
        if start != 0 {
            let msg = err.map { String(cString: $0) } ?? "session_start failed"
            if let e = err { rd_free_string(e) }
            fail(msg)
            releaseRetained()
            return
        }
        active = true

        // Prefer audio off (no local playback yet).
        if rd_session_get_toggle_option(sessionUUID, "disable-audio") == 0 {
            rd_session_toggle_option(sessionUUID, "disable-audio")
        }
        didEnsureAudio = true
        audioMuted = true

        if !password.isEmpty {
            setStage("Authenticating…")
            rd_session_login(sessionUUID, password, rememberPassword ? 1 : 0)
        } else {
            setStage("Waiting for peer…")
        }
    }

    /// Re-run the last connection (same peer / password / relay prefs).
    func reconnect() {
        guard !peerId.isEmpty else { return }
        connect(
            peerId: peerId,
            password: lastPassword,
            forceRelay: lastForceRelay,
            rememberPassword: rememberPassword
        )
    }

    func submitPassword(_ password: String) {
        guard active else { return }
        lastPassword = password
        setStage("Authenticating…")
        armConnectTimeout()
        rd_session_login(sessionUUID, password, rememberPassword ? 1 : 0)
        if rememberPassword {
            RecentPeersStore.shared.record(
                id: peerId,
                password: password,
                forceRelay: lastForceRelay,
                rememberPassword: true
            )
        }
        phase = .connecting
        statusText = "Logging in…"
    }

    func close() {
        cancelConnectTimeout()
        let wasActive = active
            || phase == .connecting
            || phase == .needPassword
            || {
                if case .failed = phase { return true }
                return false
            }()
        guard wasActive else {
            releaseRetained()
            return
        }
        softKeyboardVisible = false
        stopPasteboardObserver()
        // Release sticky modifiers on the peer while session is still active.
        if active {
            clearModifiers(sendKeyUp: true)
        }
        active = false
        if !sessionUUID.isEmpty {
            rd_session_close(sessionUUID)
        }
        phase = .closed
        statusText = "Disconnected"
        connectionStage = ""
        releaseRetained()
    }

    private func setStage(_ text: String) {
        connectionStage = text
        statusText = text
    }

    private func fail(_ message: String) {
        cancelConnectTimeout()
        lastError = message
        phase = .failed(message)
        statusText = message
        connectionStage = "Failed"
        active = false
    }

    private func armConnectTimeout() {
        cancelConnectTimeout()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.phase == .connecting || self.phase == .needPassword else { return }
            // needPassword is interactive — only timeout pure connecting.
            guard self.phase == .connecting else { return }
            self.fail("Connection timed out after \(Int(self.connectTimeoutSeconds))s. Check ID server, network, or try Force relay.")
            if !self.sessionUUID.isEmpty {
                rd_session_close(self.sessionUUID)
            }
            self.releaseRetained()
        }
        connectTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + connectTimeoutSeconds, execute: work)
    }

    private func cancelConnectTimeout() {
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
    }

    private func markConnected(summary: String? = nil) {
        cancelConnectTimeout()
        phase = .connected
        connectionStage = "Connected"
        if let summary, !summary.isEmpty {
            statusText = summary
        } else {
            statusText = connectionSummary.isEmpty ? "Connected" : "Connected · \(connectionSummary)"
        }
        refreshToggleState()
        // Once connected, resize host desktop to fill the iPad canvas.
        if lastViewW > 0, lastViewH > 0 {
            scheduleFillResolution(width: lastViewW, height: lastViewH)
        }
    }

    // MARK: - Pointer / view

    func sendMouseJSON(_ json: String) {
        guard active else { return }
        // Still allow pointer when "view only" is out of sync; peer enforces permissions.
        if viewOnly {
            // Local-only: keep cursor feedback even if we skip sending (view-only).
            updateCursorFromMouseJSON(json)
            return
        }
        // Inject Sidecar sticky modifiers (session_send_mouse checks key presence).
        let enriched = enrichMouseJSONWithModifiers(json)
        rd_session_send_mouse(sessionUUID, enriched)
        updateCursorFromMouseJSON(json)
    }

    /// Add alt/ctrl/shift/command keys when sticky modifiers are on.
    private func enrichMouseJSONWithModifiers(_ json: String) -> String {
        guard modCommand || modOption || modControl || modShift else { return json }
        guard let data = json.data(using: .utf8),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return json }
        // Values must be strings — Rust parses HashMap<String, String>.
        if modCommand { obj["command"] = "true" }
        if modOption { obj["alt"] = "true" }
        if modControl { obj["ctrl"] = "true" }
        if modShift { obj["shift"] = "true" }
        // Coerce all values to strings for the Rust ABI.
        var strMap: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String { strMap[k] = s }
            else if let i = v as? Int { strMap[k] = "\(i)" }
            else if let b = v as? Bool { strMap[k] = b ? "true" : "false" }
            else { strMap[k] = "\(v)" }
        }
        guard let out = try? JSONSerialization.data(withJSONObject: strMap),
              let s = String(data: out, encoding: .utf8)
        else { return json }
        return s
    }

    private func updateCursorFromMouseJSON(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let x = intValue(obj["x"]),
              let y = intValue(obj["y"])
        else { return }
        cursorX = CGFloat(x)
        cursorY = CGFloat(y)
        if showRemoteCursor && !cursorEmbedded {
            cursorVisible = true
        }
    }

    func setViewSize(width: Int, height: Int) {
        guard active, width > 0, height > 0 else { return }
        let display = max(0, currentDisplayIndex)
        // Soft-renderer client viewport (for letterbox math / encoder hints).
        rd_session_set_size(sessionUUID, display, width, height)
        lastViewW = width
        lastViewH = height
        // Debounce host resolution changes so rotate / layout thrash is quiet.
        scheduleFillResolution(width: width, height: height)
    }

    /// Ask the host to resize the remote desktop to fill the iPad canvas aspect.
    /// Even dimensions help video codecs; we keep a modest max edge.
    private func scheduleFillResolution(width: Int, height: Int) {
        resolutionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applyFillResolution(width: width, height: height)
        }
        resolutionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func applyFillResolution(width: Int, height: Int) {
        guard active, phase == .connected, width > 0, height > 0 else { return }
        // Even sizes; clamp so we don't request absurd host modes.
        var w = (max(640, min(width, 2560)) / 2) * 2
        var h = (max(480, min(height, 1600)) / 2) * 2
        // Skip if already essentially matching current remote size (±2%).
        if displayWidth > 0, displayHeight > 0 {
            let dw = abs(displayWidth - w)
            let dh = abs(displayHeight - h)
            if dw <= max(8, displayWidth / 50), dh <= max(8, displayHeight / 50) {
                return
            }
        }
        if w == lastRequestedResW, h == lastRequestedResH { return }
        lastRequestedResW = w
        lastRequestedResH = h
        let display = Int32(max(0, currentDisplayIndex))
        rd_session_change_resolution(sessionUUID, display, Int32(w), Int32(h))
        statusText = "Res \(w)×\(h)"
    }

    // MARK: - Multi-display

    var hasMultipleDisplays: Bool { displays.count > 1 }

    var displaySummary: String {
        guard !displays.isEmpty else { return "" }
        return "\(currentDisplayIndex + 1)/\(displays.count)"
    }

    /// Switch to a peer display by 0-based index.
    func switchDisplay(to index: Int) {
        guard active, !displays.isEmpty else { return }
        let clamped = max(0, min(index, displays.count - 1))
        currentDisplayIndex = clamped
        let d = displays[clamped]
        if d.width > 0 { displayWidth = d.width }
        if d.height > 0 { displayHeight = d.height }
        cursorEmbedded = d.cursorEmbedded
        rd_session_switch_display(sessionUUID, Int32(clamped))
        statusText = d.label
        lastClipboardNote = "" // avoid stale note
        // Reset cursor to center of new display for overlay.
        if displayWidth > 0, displayHeight > 0 {
            cursorX = CGFloat(displayWidth) / 2
            cursorY = CGFloat(displayHeight) / 2
        }
        // Re-fit host resolution for the new display using current canvas size.
        lastRequestedResW = 0
        lastRequestedResH = 0
        if lastViewW > 0, lastViewH > 0 {
            scheduleFillResolution(width: lastViewW, height: lastViewH)
        }
    }

    /// Cycle to the next peer display (no-op with a single monitor).
    func cycleDisplay() {
        guard hasMultipleDisplays else {
            statusText = "Single display"
            return
        }
        switchDisplay(to: (currentDisplayIndex + 1) % displays.count)
    }

    // MARK: - Keyboard

    /// Physical key via USB HID usage (map mode).
    func handleKey(character: String, usbHid: Int, down: Bool, lockModes: Int = 0) {
        guard active, !viewOnly, usbHid != 0 else { return }
        rd_session_handle_key(sessionUUID, character, Int32(usbHid), Int32(lockModes), down ? 1 : 0)
    }

    /// Soft-keyboard / paste text path.
    func inputString(_ value: String) {
        guard active, !viewOnly, !value.isEmpty else { return }
        rd_session_input_string(sessionUUID, value)
    }

    /// Named key (Backspace, Enter, …) with modifiers.
    func inputKey(
        name: String,
        down: Bool,
        press: Bool = false,
        alt: Bool = false,
        ctrl: Bool = false,
        shift: Bool = false,
        command: Bool = false
    ) {
        guard active, !viewOnly else { return }
        rd_session_input_key(
            sessionUUID,
            name,
            down ? 1 : 0,
            press ? 1 : 0,
            alt ? 1 : 0,
            ctrl ? 1 : 0,
            shift ? 1 : 0,
            command ? 1 : 0
        )
    }

    /// Push iOS pasteboard text into the peer's OS clipboard (true sync).
    /// Peer can then ⌘V / Ctrl+V. Prefer this over keystroke injection for large text.
    func pasteFromClipboard() {
        pushClipboardToPeer()
    }

    /// Push local pasteboard → peer system clipboard.
    func pushClipboardToPeer() {
        guard active, !viewOnly else {
            lastClipboardNote = "Not connected"
            return
        }
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            statusText = "Clipboard empty"
            lastClipboardNote = "Clipboard empty"
            return
        }
        rd_session_send_clipboard(sessionUUID, text)
        statusText = "Clipboard → peer (\(text.count) chars)"
        lastClipboardNote = "Pushed \(min(text.count, 999)) chars to peer"
        // Remember so auto-sync does not echo peer→local→peer.
        lastPushedClipboard = text
    }

    /// Type pasteboard into remote as keystrokes (legacy / when peer clipboard is disabled).
    func typeClipboardAsKeystrokes() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            statusText = "Clipboard empty"
            lastClipboardNote = "Clipboard empty"
            return
        }
        inputString(text)
        statusText = "Typed \(text.count) chars"
        lastClipboardNote = "Typed \(min(text.count, 999)) chars"
    }

    // MARK: - Sticky modifiers (Sidecar-style)

    /// USB HID left-modifier usages.
    private enum ModHID {
        static let control = 0xE0
        static let shift = 0xE1
        static let option = 0xE2
        static let command = 0xE3
    }

    func toggleCommand() { toggleModifier(\.modCommand, hid: ModHID.command, name: "⌘") }
    func toggleOption() { toggleModifier(\.modOption, hid: ModHID.option, name: "⌥") }
    func toggleControl() { toggleModifier(\.modControl, hid: ModHID.control, name: "⌃") }
    func toggleShift() { toggleModifier(\.modShift, hid: ModHID.shift, name: "⇧") }

    private func toggleModifier(_ keyPath: ReferenceWritableKeyPath<SessionController, Bool>, hid: Int, name: String) {
        let next = !self[keyPath: keyPath]
        self[keyPath: keyPath] = next
        // Hold the modifier on the peer while sticky is on.
        handleKey(character: "", usbHid: hid, down: next)
        statusText = next ? "\(name) on" : "\(name) off"
    }

    private func clearModifiers(sendKeyUp: Bool) {
        if sendKeyUp, active {
            if modCommand { handleKey(character: "", usbHid: ModHID.command, down: false) }
            if modOption { handleKey(character: "", usbHid: ModHID.option, down: false) }
            if modControl { handleKey(character: "", usbHid: ModHID.control, down: false) }
            if modShift { handleKey(character: "", usbHid: ModHID.shift, down: false) }
        }
        modCommand = false
        modOption = false
        modControl = false
        modShift = false
    }

    var modifiersSummary: String {
        var parts: [String] = []
        if modControl { parts.append("⌃") }
        if modOption { parts.append("⌥") }
        if modShift { parts.append("⇧") }
        if modCommand { parts.append("⌘") }
        return parts.isEmpty ? "" : parts.joined()
    }

    var connectionSummary: String {
        if phase != .connected && phase != .connecting { return "" }
        var bits: [String] = []
        if connectionDirect { bits.append("Direct") }
        else if phase == .connected { bits.append("Relay") }
        if connectionSecure { bits.append("Secure") }
        if !streamType.isEmpty { bits.append(streamType) }
        return bits.joined(separator: " · ")
    }

    var qualitySummary: String {
        var bits: [String] = []
        if !qualityDelay.isEmpty { bits.append("\(qualityDelay) ms") }
        if !qualityFPS.isEmpty { bits.append("\(qualityFPS) fps") }
        if !qualitySpeed.isEmpty { bits.append(qualitySpeed) }
        if !qualityCodec.isEmpty { bits.append(qualityCodec) }
        return bits.joined(separator: " · ")
    }

    // MARK: - Session options

    /// Cycle image quality via real session API.
    func cycleQuality() {
        let order = ["balanced", "best", "low"]
        let labels = ["Balanced", "Best", "Low"]
        let current = qualityLabel.lowercased()
        let idx = order.firstIndex(of: current) ?? labels.firstIndex(of: qualityLabel) ?? 0
        let next = (idx + 1) % order.count
        qualityLabel = labels[next]
        guard active else { return }
        rd_session_set_image_quality(sessionUUID, order[next])
        statusText = "Quality: \(qualityLabel)"
    }

    func toggleViewOnly() {
        guard active else { return }
        rd_session_toggle_option(sessionUUID, "view-only")
        viewOnly = rd_session_get_toggle_option(sessionUUID, "view-only") != 0
        statusText = viewOnly ? "View only" : "Control enabled"
    }

    /// Audio UI is hidden; keep peer option disabled so host skips capture when possible.
    func toggleAudioMuted() {
        // no-op while playback is disabled
    }

    func setAudioMuted(_ muted: Bool) {
        audioMuted = muted
        guard active else { return }
        let currently = rd_session_get_toggle_option(sessionUUID, "disable-audio") != 0
        // muted == true → disable-audio should be ON
        if currently != muted {
            rd_session_toggle_option(sessionUUID, "disable-audio")
        }
    }

    /// Cursor mode when remote cursor is on; touch mode when off.
    var isCursorMode: Bool { showRemoteCursor }

    func toggleRemoteCursor() {
        guard active else { return }
        rd_session_toggle_option(sessionUUID, "show-remote-cursor")
        applyCursorModeFromPeer()
        statusText = showRemoteCursor
            ? "Cursor mode"
            : "Touch mode"
    }

    func refreshToggleState() {
        guard active else { return }
        // Prefer control mode: if peer config left view-only on, turn it off once.
        ensureControlMode()
        // Sync mode from peer option (do not force either way).
        applyCursorModeFromPeer()
        // Keep remote audio disabled until host capture + playback are re-enabled.
        ensureAudioDisabled()
        audioMuted = true
        if let p = rd_session_get_image_quality(sessionUUID) {
            let q = String(cString: p)
            rd_free_string(p)
            if !q.isEmpty {
                qualityLabel = q.capitalized
            }
        }
    }

    /// Prefer remote audio off for now (once per connection).
    private func ensureAudioDisabled() {
        guard !didEnsureAudio else { return }
        didEnsureAudio = true
        let disabled = rd_session_get_toggle_option(sessionUUID, "disable-audio") != 0
        if !disabled {
            rd_session_toggle_option(sessionUUID, "disable-audio")
        }
    }

    /// Ensure we are not stuck in view-only (blocks keyboard/mouse on peer).
    private func ensureControlMode() {
        if !didEnsureControlMode {
            didEnsureControlMode = true
            let vo = rd_session_get_toggle_option(sessionUUID, "view-only") != 0
            if vo {
                rd_session_toggle_option(sessionUUID, "view-only")
            }
        }
        viewOnly = rd_session_get_toggle_option(sessionUUID, "view-only") != 0
    }

    /// `show-remote-cursor` ON → cursor/trackpad mode; OFF → absolute touch mode.
    private func applyCursorModeFromPeer() {
        showRemoteCursor = rd_session_get_toggle_option(sessionUUID, "show-remote-cursor") != 0
        if showRemoteCursor && !cursorEmbedded {
            cursorVisible = true
            // Center pointer if we never got a position yet.
            if cursorX <= 0, cursorY <= 0, displayWidth > 0, displayHeight > 0 {
                cursorX = CGFloat(displayWidth) / 2
                cursorY = CGFloat(displayHeight) / 2
            }
        } else {
            cursorVisible = false
        }
    }

    /// Move logical cursor in remote coords and send a mouse-move (cursor mode).
    func moveCursorRemote(toX x: CGFloat, y: CGFloat) {
        let dw = max(1, displayWidth)
        let dh = max(1, displayHeight)
        let nx = min(CGFloat(dw - 1), max(0, x))
        let ny = min(CGFloat(dh - 1), max(0, y))
        cursorX = nx
        cursorY = ny
        if showRemoteCursor && !cursorEmbedded {
            cursorVisible = true
        }
        guard active, !viewOnly else { return }
        let map: [String: String] = [
            "x": "\(Int(nx))",
            "y": "\(Int(ny))",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: map),
           let json = String(data: data, encoding: .utf8) {
            sendMouseJSON(json)
        }
    }

    /// Click at current remote cursor (cursor mode).
    func clickAtCursor(button: String = "left") {
        guard active, !viewOnly else { return }
        let x = "\(Int(cursorX))"
        let y = "\(Int(cursorY))"
        for type in ["down", "up"] {
            let map: [String: String] = [
                "x": x, "y": y,
                "type": type,
                "buttons": button,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: map),
               let json = String(data: data, encoding: .utf8) {
                sendMouseJSON(json) // includes sticky modifiers
            }
        }
    }

    func mouseButtonAtCursor(type: String, button: String = "left") {
        guard active, !viewOnly else { return }
        let map: [String: String] = [
            "x": "\(Int(cursorX))",
            "y": "\(Int(cursorY))",
            "type": type,
            "buttons": button,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: map),
           let json = String(data: data, encoding: .utf8) {
            sendMouseJSON(json)
        }
    }

    private func resetCursorState() {
        cursorCache.removeAll()
        currentCursorId = ""
        cursorImage = nil
        cursorX = 0
        cursorY = 0
        cursorHotX = 0
        cursorHotY = 0
        cursorVisible = false
        cursorEmbedded = false
    }

    // MARK: - Codec (VideoToolbox path)

    /// Prefer H.264/H.265 so the host encodes for VideoToolbox hard-decode.
    func applyCodecPreference() {
        guard active else { return }
        let pref = codecPreference
        UserDefaults.standard.set(pref, forKey: "codec_preference")
        rd_main_set_option("codec-preference", pref)
        rd_main_set_option("enable-hwcodec", "Y")
        rd_session_set_codec_preference(sessionUUID, pref)
        rd_session_refresh_decodings(sessionUUID)
        statusText = "Codec: \(pref.uppercased()) (VT)"
    }

    func cycleCodecPreference() {
        let order = ["h264", "h265", "auto"]
        let idx = order.firstIndex(of: codecPreference) ?? 0
        codecPreference = order[(idx + 1) % order.count]
        applyCodecPreference()
    }

    /// True when quality status reports a hard-decodable format.
    var isHardDecodeCodec: Bool {
        let c = qualityCodec.lowercased()
        return c.contains("h264") || c.contains("h265") || c.contains("hevc") || c.contains("avc")
    }

    // MARK: - Frame pull

    /// Zero-copy frame access: pointer is only valid inside `body` (before next_rgba).
    /// Returns false when no new frame is available.
    @discardableResult
    func withLatestFrame(_ body: (_ pixels: UnsafeRawPointer, _ width: Int, _ height: Int, _ bytesPerRow: Int) -> Void) -> Bool {
        guard active else { return false }
        let display = max(0, currentDisplayIndex)
        let size = rd_session_get_rgba_size(sessionUUID, display)
        guard size > 0 else { return false }
        guard let ptr = rd_session_get_rgba(sessionUUID, display) else { return false }
        var w = displayWidth
        var h = displayHeight
        if w <= 0 || h <= 0 {
            let pixels = size / 4
            w = displayWidth > 0 ? displayWidth : Int(sqrt(Double(pixels)))
            h = w > 0 ? pixels / w : 0
            if w * h * 4 != size && displayWidth > 0 {
                h = size / (4 * displayWidth)
                w = displayWidth
            }
        }
        if w <= 0 || h <= 0 || w * h * 4 > size {
            let pixels = size / 4
            w = max(1, Int(sqrt(Double(pixels))))
            h = max(1, pixels / w)
        }
        if w > 1, h > 1, (displayWidth != w || displayHeight != h) {
            if displayWidth <= 1 || displayHeight <= 1 {
                displayWidth = w
                displayHeight = h
            }
        }
        // Tight BGRA rows (iOS align=1).
        let bpr = w * 4
        body(UnsafeRawPointer(ptr), w, h, bpr)
        rd_session_next_rgba(sessionUUID, display)
        return true
    }

    private func parseDisplays(from obj: [String: Any]) {
        // displays is a JSON-encoded string array of {width,height,x,y,...}.
        var list: [[String: Any]] = []
        if let displaysStr = obj["displays"] as? String,
           let ddata = displaysStr.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: ddata) as? [[String: Any]] {
            list = arr
        } else if let arr = obj["displays"] as? [[String: Any]] {
            list = arr
        }

        if !list.isEmpty {
            displays = list.enumerated().map { idx, d in
                RemoteDisplayInfo(
                    id: idx,
                    width: intValue(d["width"]) ?? 0,
                    height: intValue(d["height"]) ?? 0,
                    x: intValue(d["x"]) ?? 0,
                    y: intValue(d["y"]) ?? 0,
                    cursorEmbedded: stringValue(d["cursor_embedded"]) == "1"
                        || intValue(d["cursor_embedded"]) == 1
                )
            }
            let cur = intValue(obj["current_display"]) ?? 0
            currentDisplayIndex = max(0, min(cur, displays.count - 1))
            let active = displays[currentDisplayIndex]
            if active.width > 0 { displayWidth = active.width }
            if active.height > 0 { displayHeight = active.height }
            cursorEmbedded = active.cursorEmbedded
        } else {
            // Fallback single display from top-level width/height.
            if displayWidth == 0, let w = intValue(obj["width"]), w > 0 { displayWidth = w }
            if displayHeight == 0, let h = intValue(obj["height"]), h > 0 { displayHeight = h }
            if displayWidth > 0, displayHeight > 0, displays.isEmpty {
                displays = [
                    RemoteDisplayInfo(
                        id: 0,
                        width: displayWidth,
                        height: displayHeight,
                        x: 0,
                        y: 0,
                        cursorEmbedded: false
                    )
                ]
                currentDisplayIndex = 0
            }
        }
        if displayWidth == 0, let w = intValue(obj["width"]), w > 0 { displayWidth = w }
        if displayHeight == 0, let h = intValue(obj["height"]), h > 0 { displayHeight = h }
    }

    private func releaseRetained() {
        if let r = retainedSelf {
            r.release()
            retainedSelf = nil
        }
    }

    fileprivate func handleEvent(kind: Int32, json: String?, display: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch kind {
            case 0:
                self.handleJSON(json ?? "")
            case 1:
                // Frame ready for `display` — ignore other monitors' buffers.
                if display == self.currentDisplayIndex || self.displays.count <= 1 {
                    self.frameTick &+= 1
                }
                if self.phase == .connecting {
                    self.markConnected()
                }
            case 2:
                self.cancelConnectTimeout()
                self.active = false
                // Don't overwrite an explicit failure with "closed".
                if case .failed = self.phase {
                    self.releaseRetained()
                    return
                }
                self.phase = .closed
                self.statusText = "Session closed"
                self.connectionStage = "Closed"
                self.releaseRetained()
            default:
                break
            }
        }
    }

    private func handleJSON(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            statusText = raw
            return
        }
        let name = obj["name"] as? String ?? ""
        switch name {
        case "peer_info":
            parseDisplays(from: obj)
            if hasMultipleDisplays {
                setStage("Peer ready · \(displaySummary) · \(displayWidth)×\(displayHeight)")
            } else {
                setStage("Peer ready \(displayWidth)×\(displayHeight)")
            }
            refreshToggleState()
            // Prefer VideoToolbox-friendly codecs once the peer is known.
            applyCodecPreference()
            // First peer_info is a strong signal we're in; keep timeout for first frame.
        case "sync_peer_info":
            // Host added/removed monitors mid-session.
            parseDisplays(from: obj)
        case "input-password", "session-login-password", "password":
            cancelConnectTimeout() // wait for user input
            phase = .needPassword
            passwordPrompt = (obj["msg"] as? String) ?? "Enter password"
            setStage(passwordPrompt)
        case "msgbox":
            let text = (obj["text"] as? String) ?? (obj["title"] as? String) ?? raw
            let typ = (obj["type"] as? String) ?? ""
            if typ.contains("error") || typ.contains("custom-error") || typ == "error" {
                fail(text)
            } else {
                statusText = text
                if phase == .connecting {
                    connectionStage = text
                }
            }
        case "connection_ready", "success":
            if let s = stringValue(obj["secure"]) {
                connectionSecure = s == "true" || s == "1"
            }
            if let d = stringValue(obj["direct"]) {
                connectionDirect = d == "true" || d == "1"
            }
            streamType = stringValue(obj["stream_type"]) ?? streamType
            markConnected()
        case "update_quality_status":
            handleQualityStatus(obj)
        case "clipboard":
            handlePeerClipboard(obj)
        case "cursor_data":
            handleCursorData(obj)
        case "cursor_id":
            handleCursorId(obj)
        case "cursor_position":
            handleCursorPosition(obj)
        case "switch_display":
            if let d = intValue(obj["display"]) {
                currentDisplayIndex = d
            }
            if let emb = obj["cursor_embedded"] {
                cursorEmbedded = stringValue(emb) == "1" || (emb as? Bool) == true
            }
            if let w = intValue(obj["width"]), w > 0 { displayWidth = w }
            if let h = intValue(obj["height"]), h > 0 { displayHeight = h }
            // Keep displays[] in sync with the active monitor's size.
            if currentDisplayIndex >= 0, currentDisplayIndex < displays.count {
                var list = displays
                list[currentDisplayIndex].width = displayWidth
                list[currentDisplayIndex].height = displayHeight
                list[currentDisplayIndex].cursorEmbedded = cursorEmbedded
                displays = list
            }
            if hasMultipleDisplays {
                statusText = "Display \(displaySummary) · \(displayWidth)×\(displayHeight)"
            }
        case "permission", "fingerprint":
            break
        case "on_connection_ready", "on-connection-ready":
            markConnected()
        default:
            if phase == .connecting {
                let label = name.isEmpty ? raw : name
                setStage(friendlyStage(label))
            }
        }
    }

    /// Map raw event names to short user-facing stages.
    private func friendlyStage(_ raw: String) -> String {
        let s = raw.lowercased()
        if s.contains("relay") { return "Connecting via relay…" }
        if s.contains("punch") || s.contains("udp") { return "Hole punching…" }
        if s.contains("handshake") || s.contains("key") { return "Securing connection…" }
        if s.contains("login") || s.contains("auth") { return "Authenticating…" }
        if s.contains("wait") { return "Waiting for peer…" }
        if raw.count > 48 { return String(raw.prefix(45)) + "…" }
        return raw
    }

    private func handleQualityStatus(_ obj: [String: Any]) {
        if let s = stringValue(obj["speed"]), !s.isEmpty { qualitySpeed = s }
        if let d = stringValue(obj["delay"]), !d.isEmpty { qualityDelay = d }
        if let c = stringValue(obj["codec_format"]), !c.isEmpty { qualityCodec = c }
        // fps is a JSON object map display→fps, or a plain number string.
        if let fpsRaw = stringValue(obj["fps"]), !fpsRaw.isEmpty {
            if let data = fpsRaw.data(using: .utf8),
               let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Prefer current display / first value.
                let key = "\(currentDisplayIndex)"
                if let v = map[key] ?? map["0"] ?? map.values.first {
                    qualityFPS = stringValue(v) ?? "\(v)"
                }
            } else {
                qualityFPS = fpsRaw
            }
        }
    }

    private func handlePeerClipboard(_ obj: [String: Any]) {
        guard let content = stringValue(obj["content"]), !content.isEmpty else { return }
        lastReceivedClipboard = content
        UIPasteboard.general.string = content
        lastClipboardNote = "Copied \(min(content.count, 999)) chars from peer"
        // Don't stomp statusText if user is mid-action; brief note is enough.
    }

    // MARK: - Clipboard auto-sync (iOS → peer)

    func startPasteboardObserver() {
        stopPasteboardObserver()
        pasteboardObserver = NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onLocalPasteboardChanged()
        }
    }

    func stopPasteboardObserver() {
        if let pasteboardObserver {
            NotificationCenter.default.removeObserver(pasteboardObserver)
            self.pasteboardObserver = nil
        }
    }

    private func onLocalPasteboardChanged() {
        guard active, phase == .connected, autoSyncClipboard, !viewOnly else { return }
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        // Suppress echo when we just received from peer or just pushed.
        if text == lastReceivedClipboard || text == lastPushedClipboard { return }
        rd_session_send_clipboard(sessionUUID, text)
        lastPushedClipboard = text
        lastClipboardNote = "Synced \(min(text.count, 999)) chars → peer"
    }

    // MARK: - Cursor events

    private func handleCursorData(_ obj: [String: Any]) {
        let id = stringValue(obj["id"]) ?? ""
        let hotx = CGFloat(doubleValue(obj["hotx"]) ?? 0)
        let hoty = CGFloat(doubleValue(obj["hoty"]) ?? 0)
        let width = intValue(obj["width"]) ?? 0
        let height = intValue(obj["height"]) ?? 0
        guard width > 0, height > 0 else { return }

        // colors is a JSON-encoded array of bytes (RGBA), itself a string field.
        var bytes: [UInt8] = []
        if let colorsStr = obj["colors"] as? String,
           let cdata = colorsStr.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: cdata) as? [Any] {
            bytes = arr.compactMap { v -> UInt8? in
                if let i = v as? Int { return UInt8(clamping: i) }
                if let n = v as? NSNumber { return UInt8(clamping: n.intValue) }
                return nil
            }
        } else if let arr = obj["colors"] as? [Any] {
            bytes = arr.compactMap { v -> UInt8? in
                if let i = v as? Int { return UInt8(clamping: i) }
                if let n = v as? NSNumber { return UInt8(clamping: n.intValue) }
                return nil
            }
        }
        guard let image = Self.makeRGBAImage(width: width, height: height, bytes: bytes) else { return }
        if !id.isEmpty {
            cursorCache[id] = (image, hotx, hoty)
            currentCursorId = id
        }
        cursorImage = image
        cursorHotX = hotx
        cursorHotY = hoty
    }

    private func handleCursorId(_ obj: [String: Any]) {
        guard let id = stringValue(obj["id"]), !id.isEmpty else { return }
        currentCursorId = id
        if let cached = cursorCache[id] {
            cursorImage = cached.image
            cursorHotX = cached.hotx
            cursorHotY = cached.hoty
        }
    }

    private func handleCursorPosition(_ obj: [String: Any]) {
        let x = doubleValue(obj["x"]) ?? 0
        let y = doubleValue(obj["y"]) ?? 0
        cursorX = CGFloat(x)
        cursorY = CGFloat(y)
        cursorVisible = showRemoteCursor && !cursorEmbedded
    }

    private static func makeRGBAImage(width: Int, height: Int, bytes: [UInt8]) -> UIImage? {
        let expected = width * height * 4
        guard bytes.count >= expected, width > 0, height > 0 else { return nil }
        var rgba = Array(bytes.prefix(expected))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let ctx = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ), let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg)
    }

    private func stringValue(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let i = v as? Int { return String(i) }
        return nil
    }

    private func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private func doubleValue(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

private func sessionEventTrampoline(user: UnsafeMutableRawPointer?, kind: Int32, json: UnsafePointer<CChar>?, display: Int) {
    guard let user else { return }
    let ctrl = Unmanaged<SessionController>.fromOpaque(user).takeUnretainedValue()
    let s: String? = json.map { String(cString: $0) }
    ctrl.handleEvent(kind: kind, json: s, display: display)
}
