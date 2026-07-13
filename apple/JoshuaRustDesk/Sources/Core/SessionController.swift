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

/// Owns one remote session: events from Rust, frame notifications, login.
final class SessionController: ObservableObject {
    @Published var phase: SessionPhase = .idle
    @Published var statusText: String = ""
    @Published var passwordPrompt: String = ""
    @Published var peerId: String = ""
    @Published var frameTick: UInt64 = 0
    @Published var displayWidth: Int = 0
    @Published var displayHeight: Int = 0

    private(set) var sessionUUID: String = ""
    private var active = false

    // Strong ref so C callback can recover self
    private var retainedSelf: Unmanaged<SessionController>?

    deinit {
        close()
    }

    func connect(peerId: String, password: String, forceRelay: Bool = false) {
        close()
        self.peerId = peerId
        sessionUUID = UUID().uuidString
        phase = .connecting
        statusText = "Connecting to \(peerId)…"

        RustDeskBridge.shared.pushNetworkOptionsToRust()

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
            rd_session_login(sessionUUID, password, 1)
        }
    }

    func submitPassword(_ password: String) {
        guard active else { return }
        rd_session_login(sessionUUID, password, 1)
        phase = .connecting
        statusText = "Logging in…"
    }

    func close() {
        guard active || phase == .connecting || phase == .needPassword else {
            releaseRetained()
            return
        }
        active = false
        if !sessionUUID.isEmpty {
            rd_session_close(sessionUUID)
        }
        phase = .closed
        statusText = "Disconnected"
        releaseRetained()
    }

    func sendMouseJSON(_ json: String) {
        guard active else { return }
        rd_session_send_mouse(sessionUUID, json)
    }

    func setViewSize(width: Int, height: Int) {
        guard active, width > 0, height > 0 else { return }
        rd_session_set_size(sessionUUID, 0, width, height)
    }

    // MARK: - Frame pull

    func pullFrame() -> (Data, Int, Int)? {
        guard active else { return nil }
        let size = rd_session_get_rgba_size(sessionUUID, 0)
        guard size > 0 else { return nil }
        guard let ptr = rd_session_get_rgba(sessionUUID, 0) else { return nil }
        // Infer size from peer info when available; fall back to square-ish
        var w = displayWidth
        var h = displayHeight
        if w <= 0 || h <= 0 {
            // BGRA 4 bytes/pixel
            let pixels = size / 4
            w = displayWidth > 0 ? displayWidth : Int(sqrt(Double(pixels)))
            h = w > 0 ? pixels / w : 0
            if w * h * 4 != size && displayWidth > 0 {
                h = size / (4 * displayWidth)
                w = displayWidth
            }
        }
        if w <= 0 || h <= 0 || w * h * 4 > size {
            // still pull and use size-based estimate
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
            // Also try top-level
            if displayWidth == 0 {
                displayWidth = obj["width"] as? Int ?? displayWidth
                displayHeight = obj["height"] as? Int ?? displayHeight
            }
            statusText = "Peer ready"
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
        default:
            // Keep last status for debugging without noise
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
