import Foundation
import Combine

/// Thread-safe wrapper around the Rust C ABI.
final class RustDeskBridge: ObservableObject {
    static let shared = RustDeskBridge()

    @Published var localId: String = "…"
    @Published var status: String = "Not initialized"
    @Published var lastError: String?

    private var bootstrapped = false

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let appDir = docs.path
        rd_main_init(appDir, "")

        // Self-host defaults (override in Settings).
        applySelfHostDefaultsIfNeeded()

        if let idPtr = rd_main_get_id() {
            localId = String(cString: idPtr)
            rd_free_string(idPtr)
        }
        status = "Rust core ready"
    }

    func applySelfHostDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "id_server") == nil {
            defaults.set("rustdesk.joshuajixu.com", forKey: "id_server")
            defaults.set("8pshWJctNSCRvhn4dqhFoMWspUo1VGDF0oFUo2xozN0=", forKey: "key")
            defaults.set(true, forKey: "enable_udp_punch")
        }
        pushNetworkOptionsToRust()
    }

    func pushNetworkOptionsToRust() {
        let d = UserDefaults.standard
        let server = d.string(forKey: "id_server") ?? ""
        let key = d.string(forKey: "key") ?? ""
        rd_main_set_option("custom-rendezvous-server", server)
        rd_main_set_option("key", key)
        // Relay empty → derived from ID server by Rust when needed
        if let relay = d.string(forKey: "relay_server"), !relay.isEmpty {
            rd_main_set_option("relay-server", relay)
        }
        let punch = d.bool(forKey: "enable_udp_punch")
        // Local option via main option path — punch is local config in Flutter;
        // for native we set as option string used by get_local_option path if available.
        // Upstream stores enable-udp-punch in LocalConfig; map via option key.
        rd_main_set_option("enable-udp-punch", punch ? "Y" : "N")
        let ipv6 = d.bool(forKey: "enable_ipv6_punch")
        rd_main_set_option("enable-ipv6-punch", ipv6 ? "Y" : "N")

        // VideoToolbox hard-decode: keep enabled so host can send H.264/H.265.
        let hw = d.object(forKey: "enable_hwcodec") as? Bool ?? true
        rd_main_set_option("enable-hwcodec", hw ? "Y" : "N")
        let pref = d.string(forKey: "codec_preference") ?? "h264"
        rd_main_set_option("codec-preference", pref)
    }

    func getOption(_ key: String) -> String {
        guard let p = rd_main_get_option(key) else { return "" }
        defer { rd_free_string(p) }
        return String(cString: p)
    }
}
