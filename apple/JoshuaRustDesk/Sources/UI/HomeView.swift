import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject var bridge: RustDeskBridge
    @StateObject private var session = SessionController()
    @StateObject private var recents = RecentPeersStore.shared
    @State private var peerId = ""
    @State private var password = ""
    @State private var showRemote = false
    @AppStorage("force_relay") private var forceRelay = false
    @AppStorage("remember_password") private var rememberPassword = true

    private var trimmedPeerId: String {
        peerId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canConnect: Bool {
        !trimmedPeerId.isEmpty
    }

    var body: some View {
        Form {
            Section("This device") {
                HStack {
                    LabeledContent("ID", value: bridge.localId)
                    if !bridge.localId.isEmpty, bridge.localId != "—" {
                        Button {
                            UIPasteboard.general.string = bridge.localId
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Copy device ID")
                    }
                }
                Text(bridge.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    TextField("Peer ID", text: $peerId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numberPad)
                        .onChange(of: peerId) { newValue in
                            // Strip non-digits (IDs are numeric).
                            let filtered = newValue.filter(\.isNumber)
                            if filtered != newValue { peerId = filtered }
                        }
                    Button {
                        if let s = UIPasteboard.general.string {
                            peerId = s.filter(\.isNumber)
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Paste peer ID")
                }
                SecureField("Password (optional)", text: $password)
                Toggle("Force relay", isOn: $forceRelay)
                Toggle("Remember password", isOn: $rememberPassword)
                Button {
                    startConnect(
                        id: trimmedPeerId,
                        password: password,
                        forceRelay: forceRelay
                    )
                } label: {
                    HStack {
                        Spacer()
                        if session.phase == .connecting {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Text(session.phase == .connecting ? "Connecting…" : "Connect")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!canConnect || session.phase == .connecting)
            } header: {
                Text("Connect")
            } footer: {
                Text("Use Force relay if direct/P2P fails on restrictive networks.")
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
                            HStack(spacing: 12) {
                                Image(systemName: "desktopcomputer")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.displayName)
                                        .foregroundStyle(.primary)
                                    HStack(spacing: 6) {
                                        if peer.forceRelay {
                                            Text("Relay")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(Color.orange.opacity(0.15), in: Capsule())
                                                .foregroundStyle(.orange)
                                        }
                                        if !peer.lastPassword.isEmpty {
                                            Image(systemName: "key.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        if peer.lastConnected > .distantPast {
                                            Text(peer.lastConnected, style: .relative)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contextMenu {
                            Button {
                                peerId = peer.id
                                if !peer.lastPassword.isEmpty { password = peer.lastPassword }
                            } label: {
                                Label("Fill form", systemImage: "square.and.pencil")
                            }
                            Button {
                                UIPasteboard.general.string = peer.id
                            } label: {
                                Label("Copy ID", systemImage: "doc.on.doc")
                            }
                            Button(role: .destructive) {
                                recents.remove(peer.id)
                            } label: {
                                Label("Remove", systemImage: "trash")
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
                    Text("Tap to reconnect. Long-press for more. Swipe to remove.")
                }
            }

            if case .failed(let msg) = session.phase, !showRemote {
                Section {
                    Text(msg)
                        .foregroundStyle(.red)
                        .font(.footnote)
                    HStack {
                        Button("Retry") {
                            if !session.peerId.isEmpty {
                                peerId = session.peerId
                                showRemote = true
                                session.reconnect()
                            } else if canConnect {
                                startConnect(id: trimmedPeerId, password: password, forceRelay: forceRelay)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Dismiss") {
                            session.close()
                        }
                        .buttonStyle(.bordered)
                    }
                } header: {
                    Text("Last error")
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
        .onChange(of: session.phase) { newPhase in
            // If we failed while the remote host is up, keep it so user sees overlay + retry.
            // If closed from session UI, showRemote is already false.
            if case .closed = newPhase, showRemote {
                // Session closed from remote (peer end) — drop back home.
                showRemote = false
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
