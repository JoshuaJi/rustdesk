import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var bridge: RustDeskBridge
    /// Empty ID server / key → official public RustDesk (rs-ny.rustdesk.com).
    @AppStorage("id_server") private var idServer = ""
    @AppStorage("relay_server") private var relayServer = ""
    @AppStorage("key") private var key = ""
    @AppStorage("enable_udp_punch") private var enableUdpPunch = true
    @AppStorage("enable_ipv6_punch") private var enableIpv6Punch = false
    @AppStorage("enable_hwcodec") private var enableHwcodec = true
    @AppStorage("codec_preference") private var codecPreference = "h264"

    private var usingOfficialServer: Bool {
        idServer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("ID server", text: $idServer, prompt: Text("Official (empty)"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
                TextField("Relay server", text: $relayServer, prompt: Text("Optional"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
                TextField("Key", text: $key, prompt: Text("Official (empty)"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            } header: {
                Text("ID / Relay server")
            } footer: {
                if usingOfficialServer {
                    Text("Empty ID server uses the official RustDesk public network (rs-ny.rustdesk.com). Fill these only for a self-hosted server.")
                } else {
                    Text("Custom ID server. Clear ID server and key to return to the official public network.")
                }
            }

            Section {
                Toggle("Enable UDP hole punching", isOn: $enableUdpPunch)
                Toggle("Enable IPv6 P2P connection", isOn: $enableIpv6Punch)
            } header: {
                Text("Connection")
            }

            Section {
                Toggle("Hardware decode (VideoToolbox)", isOn: $enableHwcodec)
                // navigationLink opens a real list on iPhone (default/.menu often feel dead).
                Picker("Prefer codec", selection: $codecPreference) {
                    Text("Auto").tag("auto")
                    Text("H.264 (VT)").tag("h264")
                    Text("H.265 (VT)").tag("h265")
                    Text("VP8").tag("vp8")
                    Text("VP9").tag("vp9")
                    Text("AV1").tag("av1")
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("Video (VideoToolbox)")
            } footer: {
                Text("H.264/H.265 use on-device VideoToolbox hard-decode. Soft codecs (VP8/AV1) use more CPU.")
            }

            Section {
                Button("Apply network settings") {
                    bridge.pushNetworkOptionsToRust()
                }
            }

            Section("About") {
                Text("Native Swift client (no Flutter)")
                Text(
                    usingOfficialServer
                        ? "Network: official RustDesk public servers"
                        : "Network: \(idServer.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        // Explicit interactive content — avoids hit-testing dead zones in some sheets.
        .scrollContentBackground(.visible)
        .onDisappear {
            bridge.pushNetworkOptionsToRust()
        }
    }
}
