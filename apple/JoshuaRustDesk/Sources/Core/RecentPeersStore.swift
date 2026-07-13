import Foundation

/// One remembered connection (local app history; not the same as Rust PeerConfig disk).
struct RecentPeer: Codable, Identifiable, Equatable {
    var id: String
    var alias: String
    var lastPassword: String
    var forceRelay: Bool
    var lastConnected: Date

    var displayName: String {
        alias.isEmpty ? id : "\(alias) (\(id))"
    }
}

/// Local connection history + optional password remember.
final class RecentPeersStore: ObservableObject {
    static let shared = RecentPeersStore()
    private let key = "recent_peers_v1"
    private let maxCount = 20

    @Published private(set) var peers: [RecentPeer] = []
    /// Peers discovered from Rust PeerConfig (no passwords).
    @Published private(set) var rustPeers: [RecentPeer] = []

    init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RecentPeer].self, from: data)
        else {
            peers = []
            return
        }
        peers = decoded.sorted { $0.lastConnected > $1.lastConnected }
    }

    func save() {
        if let data = try? JSONEncoder().encode(peers) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func record(id: String, password: String, forceRelay: Bool, rememberPassword: Bool, alias: String = "") {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        peers.removeAll { $0.id == trimmed }
        let entry = RecentPeer(
            id: trimmed,
            alias: alias,
            lastPassword: rememberPassword ? password : "",
            forceRelay: forceRelay,
            lastConnected: Date()
        )
        peers.insert(entry, at: 0)
        if peers.count > maxCount {
            peers = Array(peers.prefix(maxCount))
        }
        save()
    }

    func remove(_ id: String) {
        peers.removeAll { $0.id == id }
        save()
    }

    func clear() {
        peers = []
        save()
    }

    /// Merge list from `rd_main_recent_peers_json` into `rustPeers`.
    func reloadFromRust() {
        guard let p = rd_main_recent_peers_json() else {
            rustPeers = []
            return
        }
        defer { rd_free_string(p) }
        let raw = String(cString: p)
        guard let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            rustPeers = []
            return
        }
        rustPeers = arr.compactMap { obj in
            guard let id = obj["id"] as? String, !id.isEmpty else { return nil }
            let alias = (obj["alias"] as? String)
                ?? (obj["hostname"] as? String)
                ?? (obj["username"] as? String)
                ?? ""
            // Prefer local password if we have one.
            let local = peers.first { $0.id == id }
            return RecentPeer(
                id: id,
                alias: alias.isEmpty ? (local?.alias ?? "") : alias,
                lastPassword: local?.lastPassword ?? "",
                forceRelay: local?.forceRelay ?? false,
                lastConnected: local?.lastConnected ?? .distantPast
            )
        }
    }

    /// Combined list: local history first, then rust peers not already listed.
    var combined: [RecentPeer] {
        var seen = Set(peers.map(\.id))
        var out = peers
        for r in rustPeers where !seen.contains(r.id) {
            out.append(r)
            seen.insert(r.id)
        }
        return out
    }
}
