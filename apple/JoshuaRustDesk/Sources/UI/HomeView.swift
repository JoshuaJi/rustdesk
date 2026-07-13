import SwiftUI

struct HomeView: View {
    @EnvironmentObject var bridge: RustDeskBridge
    @StateObject private var session = SessionController()
    @StateObject private var recents = RecentPeersStore.shared
    @State private var peerId = ""
    @State private var password = ""
    @State private var showRemote = false
    @AppStorage("force_relay") private var forceRelay = false
    @AppStorage("remember_password") private var rememberPassword = true

    var body: some View {
        Form {
            Section("This device") {
                LabeledContent("ID", value: bridge.localId)
                Text(bridge.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Connect") {
                TextField("Peer ID", text: $peerId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numberPad)
                SecureField("Password (optional)", text: $password)
                Toggle("Force relay", isOn: $forceRelay)
                Toggle("Remember password", isOn: $rememberPassword)
                Button("Connect") {
                    startConnect(
                        id: peerId.trimmingCharacters(in: .whitespacesAndNewlines),
                        password: password,
                        forceRelay: forceRelay
                    )
                }
                .disabled(peerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !recents.combined.isEmpty {
                Section {
                    ForEach(recents.combined) { peer in
                        Button {
                            peerId = peer.id
                            if !peer.lastPassword.isEmpty {
                                password = peer.lastPassword
                            }
                            startConnect(
                                id: peer.id,
                                password: peer.lastPassword.isEmpty ? password : peer.lastPassword,
                                forceRelay: peer.forceRelay || forceRelay
                            )
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.displayName)
                                        .foregroundStyle(.primary)
                                    if peer.lastConnected > .distantPast {
                                        Text(peer.lastConnected, style: .relative)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                recents.remove(peer.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    if !recents.peers.isEmpty {
                        Button("Clear history", role: .destructive) {
                            recents.clear()
                        }
                    }
                } header: {
                    Text("Recent")
                } footer: {
                    Text("Tap to reconnect. Swipe to remove from local history.")
                }
            }

            if case .failed(let msg) = session.phase {
                Section("Error") {
                    Text(msg).foregroundStyle(.red)
                }
            }
        }
        // UIKit overFullScreen host — does not shrink for the software keyboard
        // (SwiftUI fullScreenCover still applies keyboard safe-area insets).
        .background(
            RemoteSessionPresenter(isPresented: $showRemote, session: session)
                .frame(width: 0, height: 0)
        )
        .onChange(of: showRemote) { presented in
            if !presented {
                session.close()
                recents.reloadFromRust()
            }
        }
        .onAppear {
            recents.load()
            recents.reloadFromRust()
        }
    }

    private func startConnect(id: String, password: String, forceRelay: Bool) {
        guard !id.isEmpty else { return }
        bridge.pushNetworkOptionsToRust()
        session.connect(
            peerId: id,
            password: password,
            forceRelay: forceRelay,
            rememberPassword: rememberPassword
        )
        showRemote = true
    }
}
