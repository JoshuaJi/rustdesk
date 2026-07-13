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

/// Owns one remote session: events from Rust, frame notifications, login, input.
final class SessionController: ObservableObject {
    @Published var phase: SessionPhase = .idle
    @Published var statusText: String = ""
    @Published var passwordPrompt: String = ""
    @Published var peerId: String = ""
    @Published var frameTick: UInt64 = 0
    @Published var displayWidth: Int = 0
    @Published var displayHeight: Int = 0
    /// Soft-keyboard toggle (bound by toolbar / Metal view).
    @Published var softKeyboardVisible: Bool = false
    /// Steal iPadOS system shortcuts (⌘C etc.) when possible.
    @Published var captureSystemShortcuts: Bool = true
    /// Simple quality label for toolbar.
    @Published var qualityLabel: String = "Balanced"
    @Published var viewOnly: Bool = false
    @Published var showRemoteCursor: Bool = true
    /// Remote peer cursor (display coords) + image for overlay.
    @Published private(set) var cursorX: CGFloat = 0
    @Published private(set) var cursorY: CGFloat = 0
    @Published private(set) var cursorHotX: CGFloat = 0
    @Published private(set) var cursorHotY: CGFloat = 0
    @Published private(set) var cursorImage: UIImage?
    @Published private(set) var cursorVisible: Bool = false
    /// When peer embeds cursor in the video stream, hide our overlay.
    @Published private(set) var cursorEmbedded: Bool = false

    private(set) var sessionUUID: String = ""
    private var active = false
    private var lastPassword: String = ""
    private var lastForceRelay = false
    private var rememberPassword = false
    private var cursorCache: [String: (image: UIImage, hotx: CGFloat, hoty: CGFloat)] = [:]
    private var currentCursorId: String = ""
    /// Only auto-disable view-only once per connection (don't fight user's toggle).
    private var didEnsureControlMode = false

    // Strong ref so C callback can recover self
    private var retainedSelf: Unmanaged<SessionController>?

    deinit {
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
        statusText = "Connecting to \(peerId)…"
        softKeyboardVisible = false
        viewOnly = false
        didEnsureControlMode = false
        resetCursorState()

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
            phase = .failed(msg)
            return
        }

        retainedSelf = Unmanaged.passRetained(self)
        let user = retainedSelf!.toOpaque()

        err = nil
        let start = rd_session_start(sessionUUID, peerId, sessionEventTrampoline, user, &err)
        if start != 0 {
            let msg = err.map { String(cString: $0) } ?? "session_start failed"
            if let e = err { rd_free_string(e) }
            phase = .failed(msg)
            releaseRetained()
            return
        }
        active = true

        if !password.isEmpty {
            rd_session_login(sessionUUID, password, rememberPassword ? 1 : 0)
        }
    }

    func submitPassword(_ password: String) {
        guard active else { return }
        lastPassword = password
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
        guard active || phase == .connecting || phase == .needPassword else {
            releaseRetained()
            return
        }
        active = false
        softKeyboardVisible = false
        if !sessionUUID.isEmpty {
            rd_session_close(sessionUUID)
        }
        phase = .closed
        statusText = "Disconnected"
        releaseRetained()
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
        rd_session_send_mouse(sessionUUID, json)
        updateCursorFromMouseJSON(json)
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
        rd_session_set_size(sessionUUID, 0, width, height)
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

    /// Paste from iOS pasteboard into remote as text.
    func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            statusText = "Clipboard empty"
            return
        }
        inputString(text)
        statusText = "Pasted \(text.count) chars"
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

    /// Cursor mode when remote cursor is on; touch mode when off.
    var isCursorMode: Bool { showRemoteCursor }

    func toggleRemoteCursor() {
        guard active else { return }
        rd_session_toggle_option(sessionUUID, "show-remote-cursor")
        applyCursorModeFromPeer()
        statusText = showRemoteCursor
            ? "Cursor mode — drag moves pointer, tap clicks"
            : "Touch mode — finger is the pointer"
    }

    func refreshToggleState() {
        guard active else { return }
        // Prefer control mode: if peer config left view-only on, turn it off once.
        ensureControlMode()
        // Sync mode from peer option (do not force either way).
        applyCursorModeFromPeer()
        if let p = rd_session_get_image_quality(sessionUUID) {
            let q = String(cString: p)
            rd_free_string(p)
            if !q.isEmpty {
                qualityLabel = q.capitalized
            }
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
            rd_session_send_mouse(sessionUUID, json)
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
                rd_session_send_mouse(sessionUUID, json)
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
            rd_session_send_mouse(sessionUUID, json)
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

    // MARK: - Frame pull

    func pullFrame() -> (Data, Int, Int)? {
        guard active else { return nil }
        let size = rd_session_get_rgba_size(sessionUUID, 0)
        guard size > 0 else { return nil }
        guard let ptr = rd_session_get_rgba(sessionUUID, 0) else { return nil }
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
        // Soft-render path: adopt actual frame size when peer_info width was missing.
        if w > 1, h > 1, (displayWidth != w || displayHeight != h) {
            // Only auto-fill when unknown; don't fight multi-monitor switch.
            if displayWidth <= 1 || displayHeight <= 1 {
                displayWidth = w
                displayHeight = h
            }
        }
        let data = Data(bytes: ptr, count: min(size, w * h * 4))
        rd_session_next_rgba(sessionUUID, 0)
        return (data, w, h)
    }

    private func parseDisplays(from obj: [String: Any]) {
        // displays is a JSON-encoded string array of {width,height,...} (ints as NSNumber).
        if let displays = obj["displays"] as? String,
           let ddata = displays.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: ddata) as? [[String: Any]],
           let first = arr.first {
            if let w = intValue(first["width"]), w > 0 { displayWidth = w }
            if let h = intValue(first["height"]), h > 0 { displayHeight = h }
            if let emb = first["cursor_embedded"] {
                cursorEmbedded = stringValue(emb) == "1" || intValue(emb) == 1
            }
        } else if let arr = obj["displays"] as? [[String: Any]], let first = arr.first {
            if let w = intValue(first["width"]), w > 0 { displayWidth = w }
            if let h = intValue(first["height"]), h > 0 { displayHeight = h }
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
                self.frameTick &+= 1
                if self.phase == .connecting {
                    self.phase = .connected
                    self.statusText = "Connected"
                    self.refreshToggleState()
                }
            case 2:
                self.active = false
                self.phase = .closed
                self.statusText = "Session closed"
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
            statusText = "Peer ready \(displayWidth)×\(displayHeight)"
            refreshToggleState()
        case "input-password", "session-login-password", "password":
            phase = .needPassword
            passwordPrompt = (obj["msg"] as? String) ?? "Enter password"
            statusText = passwordPrompt
        case "msgbox":
            let text = (obj["text"] as? String) ?? (obj["title"] as? String) ?? raw
            if (obj["type"] as? String)?.contains("error") == true {
                phase = .failed(text)
            }
            statusText = text
        case "connection_ready", "success":
            phase = .connected
            statusText = "Connected"
            refreshToggleState()
        case "cursor_data":
            handleCursorData(obj)
        case "cursor_id":
            handleCursorId(obj)
        case "cursor_position":
            handleCursorPosition(obj)
        case "switch_display":
            if let emb = obj["cursor_embedded"] {
                cursorEmbedded = stringValue(emb) == "1" || (emb as? Bool) == true
            }
            if let w = intValue(obj["width"]), w > 0 { displayWidth = w }
            if let h = intValue(obj["height"]), h > 0 { displayHeight = h }
        case "permission", "clipboard":
            break
        default:
            if phase == .connecting {
                statusText = name.isEmpty ? raw : name
            }
        }
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
