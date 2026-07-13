import SwiftUI
import UIKit

// MARK: - Home (Keynote-style document picker)

struct HomeView: View {
    @EnvironmentObject var bridge: RustDeskBridge
    @StateObject private var session = SessionController()
    @StateObject private var recents = RecentPeersStore.shared
    @State private var peerId = ""
    @State private var password = ""
    @State private var showRemote = false
    @State private var showNewConnection = false
    @State private var connectError: String?
    @AppStorage("force_relay") private var forceRelay = false
    @AppStorage("remember_password") private var rememberPassword = true

    private var trimmedPeerId: String {
        peerId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canConnect: Bool {
        !trimmedPeerId.isEmpty
    }

    /// Keynote-like adaptive tile width.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                deviceHeader

                LazyVGrid(columns: columns, spacing: 28) {
                    // “+” always first — Keynote create tile
                    NewDocumentTile {
                        peerId = ""
                        password = ""
                        connectError = nil
                        showNewConnection = true
                    }

                    ForEach(recents.combined) { peer in
                        PeerDocumentTile(
                            peer: peer,
                            isConnecting: session.phase == .connecting && session.peerId == peer.id
                        ) {
                            startConnect(
                                id: peer.id,
                                password: peer.lastPassword.isEmpty ? password : peer.lastPassword,
                                forceRelay: peer.forceRelay || forceRelay
                            )
                        }
                        .contextMenu {
                            peerContextMenu(peer)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)

                if let connectError, !showRemote {
                    errorBanner(connectError)
                        .padding(.horizontal, 20)
                }
            }
            .padding(.top, 8)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .sheet(isPresented: $showNewConnection) {
            NewConnectionSheet(
                peerId: $peerId,
                password: $password,
                forceRelay: $forceRelay,
                rememberPassword: $rememberPassword,
                isConnecting: session.phase == .connecting,
                canConnect: canConnect,
                onConnect: {
                    startConnect(id: trimmedPeerId, password: password, forceRelay: forceRelay)
                    showNewConnection = false
                },
                onCancel: { showNewConnection = false }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .background(
            RemoteSessionPresenter(isPresented: $showRemote, session: session)
                .frame(width: 0, height: 0)
        )
        .onChange(of: showRemote) { presented in
            if !presented {
                session.close()
                recents.reloadFromRust()
                if case .failed(let msg) = session.phase {
                    connectError = msg
                }
            }
        }
        .onChange(of: session.phase) { newPhase in
            if case .closed = newPhase, showRemote {
                showRemote = false
            }
            if case .failed(let msg) = newPhase, !showRemote {
                connectError = msg
            }
            if case .connecting = newPhase {
                connectError = nil
            }
        }
        .onAppear {
            recents.load()
            recents.reloadFromRust()
        }
    }

    // MARK: Header — this device (quiet, secondary)

    private var deviceHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connections")
                    .font(.largeTitle.weight(.bold))
                HStack(spacing: 8) {
                    Text("This device")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(bridge.localId.isEmpty ? "—" : bridge.localId)
                        .font(.subheadline.monospacedDigit().weight(.medium))
                        .foregroundStyle(.primary)
                    if !bridge.localId.isEmpty, bridge.localId != "—" {
                        Button {
                            UIPasteboard.general.string = bridge.localId
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Copy device ID")
                    }
                }
                Text(bridge.status)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !recents.peers.isEmpty {
                Menu {
                    Button("Clear history", role: .destructive) {
                        recents.clear()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    private func errorBanner(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(msg)
                .font(.footnote)
                .foregroundStyle(.red)
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
                .tint(.white)
                Button("Dismiss") {
                    connectError = nil
                    session.close()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func peerContextMenu(_ peer: RecentPeer) -> some View {
        Button {
            peerId = peer.id
            if !peer.lastPassword.isEmpty { password = peer.lastPassword }
            forceRelay = peer.forceRelay || forceRelay
            showNewConnection = true
        } label: {
            Label("Edit & connect", systemImage: "square.and.pencil")
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

    private func startConnect(id: String, password: String, forceRelay: Bool) {
        guard !id.isEmpty else { return }
        connectError = nil
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

// MARK: - New “+” tile (Keynote create presentation)

private struct NewDocumentTile: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            Color.primary.opacity(0.12),
                            style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                        )
                    Image(systemName: "plus")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.85))
                }
                .aspectRatio(4 / 3, contentMode: .fit)

                Text("New Connection")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(" ")
                    .font(.caption2)
                    .opacity(0)
            }
        }
        .buttonStyle(DocumentTileButtonStyle())
        .accessibilityLabel("New connection")
    }
}

// MARK: - Peer document tile

private struct PeerDocumentTile: View {
    let peer: RecentPeer
    var isConnecting: Bool = false
    var action: () -> Void

    private var title: String {
        peer.alias.isEmpty ? peer.id : peer.alias
    }

    private var subtitle: String {
        if peer.alias.isEmpty {
            if peer.lastConnected > .distantPast {
                return relativeDate
            }
            return "Remote desktop"
        }
        return peer.id
    }

    private var relativeDate: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: peer.lastConnected, relativeTo: Date())
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    // Slide-like thumbnail
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.14, green: 0.16, blue: 0.20),
                                    Color(red: 0.08, green: 0.09, blue: 0.12),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: .black.opacity(0.28), radius: 10, y: 5)

                    // Fake “desktop” chrome
                    VStack(spacing: 0) {
                        HStack(spacing: 4) {
                            Circle().fill(Color.red.opacity(0.55)).frame(width: 6, height: 6)
                            Circle().fill(Color.yellow.opacity(0.55)).frame(width: 6, height: 6)
                            Circle().fill(Color.green.opacity(0.55)).frame(width: 6, height: 6)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 6)

                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .overlay {
                                if isConnecting {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "desktopcomputer")
                                        .font(.system(size: 28, weight: .light))
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                    }

                    // Badges
                    VStack {
                        HStack {
                            Spacer()
                            if peer.forceRelay {
                                Text("Relay")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                        }
                        Spacer()
                        HStack {
                            if !peer.lastPassword.isEmpty {
                                Image(systemName: "key.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.7))
                                    .padding(5)
                                    .background(Color.black.opacity(0.35), in: Circle())
                            }
                            Spacer()
                        }
                    }
                    .padding(8)
                }
                .aspectRatio(4 / 3, contentMode: .fit)

                VStack(spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(DocumentTileButtonStyle())
        .accessibilityLabel("Connect to \(title)")
    }
}

// MARK: - Press feedback

private struct DocumentTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - New connection sheet (form moved off the home grid)

private struct NewConnectionSheet: View {
    @Binding var peerId: String
    @Binding var password: String
    @Binding var forceRelay: Bool
    @Binding var rememberPassword: Bool
    var isConnecting: Bool
    var canConnect: Bool
    var onConnect: () -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Peer ID", text: $peerId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numberPad)
                            .onChange(of: peerId) { newValue in
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
                } footer: {
                    Text("Use Force relay if direct/P2P fails on restrictive networks.")
                }
            }
            .navigationTitle("New Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onConnect()
                    } label: {
                        if isConnecting {
                            ProgressView()
                        } else {
                            Text("Connect")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(!canConnect || isConnecting)
                }
            }
        }
    }
}
