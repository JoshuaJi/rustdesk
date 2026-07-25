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

        // Empty ID/key/relay → official public servers (rs-ny.rustdesk.com + RS_PUB_KEY).
        applyNetworkDefaultsIfNeeded()

        if let idPtr = rd_main_get_id() {
            localId = String(cString: idPtr)
            rd_free_string(idPtr)
        }
        status = "Rust core ready"
    }

    /// Empty ID server / key means official RustDesk public infra.
    /// Self-host by filling Settings (ID server + key).
    func applyNetworkDefaultsIfNeeded() {
        let defaults = UserDefaults.standard

        // One-time: drop the previous hard-coded self-host seed so the product
        // default is official (empty fields). Custom self-host values that are
        // not exactly the old seed are left alone.
        if defaults.string(forKey: "id_server") == Self.legacySelfHostServer {
            defaults.set("", forKey: "id_server")
        }
        if defaults.string(forKey: "key") == Self.legacySelfHostKey {
            defaults.set("", forKey: "key")
        }

        if defaults.object(forKey: "id_server") == nil {
            defaults.set("", forKey: "id_server")
        }
        if defaults.object(forKey: "key") == nil {
            defaults.set("", forKey: "key")
        }
        if defaults.object(forKey: "relay_server") == nil {
            defaults.set("", forKey: "relay_server")
        }
        if defaults.object(forKey: "enable_udp_punch") == nil {
            defaults.set(true, forKey: "enable_udp_punch")
        }

        pushNetworkOptionsToRust()
    }

    func pushNetworkOptionsToRust() {
        let d = UserDefaults.standard
        // Trim whitespace so accidental spaces don't disable official fallback.
        let server = (d.string(forKey: "id_server") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (d.string(forKey: "key") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let relay = (d.string(forKey: "relay_server") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty custom-rendezvous-server → Rust uses RENDEZVOUS_SERVERS (official).
        // Empty key → Rust get_key() falls back to RS_PUB_KEY.
        rd_main_set_option("custom-rendezvous-server", server)
        rd_main_set_option("key", key)
        // Always set so clearing Settings actually clears a prior self-host relay.
        rd_main_set_option("relay-server", relay)

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

    /// Previous product seed — cleared on bootstrap so default is official.
    private static let legacySelfHostServer = "rustdesk.joshuajixu.com"
    private static let legacySelfHostKey =
        "8pshWJctNSCRvhn4dqhFoMWspUo1VGDF0oFUo2xozN0="

    func getOption(_ key: String) -> String {
        guard let p = rd_main_get_option(key) else { return "" }
        defer { rd_free_string(p) }
        return String(cString: p)
    }
}
