import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var bridge: RustDeskBridge
    @AppStorage("id_server") private var idServer = "rustdesk.joshuajixu.com"
    @AppStorage("relay_server") private var relayServer = ""
    @AppStorage("key") private var key = "8pshWJctNSCRvhn4dqhFoMWspUo1VGDF0oFUo2xozN0="
    @AppStorage("enable_udp_punch") private var enableUdpPunch = true
    @AppStorage("enable_ipv6_punch") private var enableIpv6Punch = false

    var body: some View {
        Form {
            Section("ID / Relay server") {
                TextField("ID server", text: $idServer)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Relay server (optional)", text: $relayServer)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("Connection") {
                Toggle("Enable UDP hole punching", isOn: $enableUdpPunch)
                Toggle("Enable IPv6 P2P connection", isOn: $enableIpv6Punch)
            }
            Section {
                Button("Apply to Rust core") {
                    bridge.pushNetworkOptionsToRust()
                }
            }
            Section("About") {
                Text("Native Swift client (no Flutter)")
                Text("Self-host: rustdesk.joshuajixu.com")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .onDisappear {
            bridge.pushNetworkOptionsToRust()
        }
    }
}
