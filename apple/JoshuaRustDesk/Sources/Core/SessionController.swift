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

    private(set) var sessionUUID: String = ""
    private var active = false
    private var lastPassword: String = ""
    private var lastForceRelay = false
    private var rememberPassword = false

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
        guard active, !viewOnly else { return }
        rd_session_send_mouse(sessionUUID, json)
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

    func toggleRemoteCursor() {
        guard active else { return }
        rd_session_toggle_option(sessionUUID, "show-remote-cursor")
        showRemoteCursor = rd_session_get_toggle_option(sessionUUID, "show-remote-cursor") != 0
        statusText = showRemoteCursor ? "Remote cursor on" : "Remote cursor off"
    }

    func refreshToggleState() {
        guard active else { return }
        viewOnly = rd_session_get_toggle_option(sessionUUID, "view-only") != 0
        showRemoteCursor = rd_session_get_toggle_option(sessionUUID, "show-remote-cursor") != 0
        if let p = rd_session_get_image_quality(sessionUUID) {
            let q = String(cString: p)
            rd_free_string(p)
            if !q.isEmpty {
                qualityLabel = q.capitalized
            }
        }
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
        let data = Data(bytes: ptr, count: min(size, w * h * 4))
        rd_session_next_rgba(sessionUUID, 0)
        return (data, w, h)
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
            if let displays = obj["displays"] as? String,
               let ddata = displays.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: ddata) as? [[String: Any]],
               let first = arr.first {
                displayWidth = first["width"] as? Int ?? 0
                displayHeight = first["height"] as? Int ?? 0
            }
            if displayWidth == 0 {
                displayWidth = obj["width"] as? Int ?? displayWidth
                displayHeight = obj["height"] as? Int ?? displayHeight
            }
            statusText = "Peer ready"
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
        case "cursor_data", "cursor_id", "cursor_position", "permission", "clipboard":
            break
        default:
            if phase == .connecting {
                statusText = name.isEmpty ? raw : name
            }
        }
    }
}

private func sessionEventTrampoline(user: UnsafeMutableRawPointer?, kind: Int32, json: UnsafePointer<CChar>?, display: Int) {
    guard let user else { return }
    let ctrl = Unmanaged<SessionController>.fromOpaque(user).takeUnretainedValue()
    let s: String? = json.map { String(cString: $0) }
    ctrl.handleEvent(kind: kind, json: s, display: display)
}
