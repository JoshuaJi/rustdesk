import SwiftUI

struct HomeView: View {
    @EnvironmentObject var bridge: RustDeskBridge
    @StateObject private var session = SessionController()
    @State private var peerId = ""
    @State private var password = ""
    @State private var showRemote = false
    @State private var promptPassword = ""

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
                Button("Connect") {
                    bridge.pushNetworkOptionsToRust()
                    session.connect(peerId: peerId.trimmingCharacters(in: .whitespaces), password: password)
                    showRemote = true
                }
                .disabled(peerId.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if case .failed(let msg) = session.phase {
                Section("Error") {
                    Text(msg).foregroundStyle(.red)
                }
            }
        }
        .fullScreenCover(isPresented: $showRemote, onDismiss: {
            session.close()
        }) {
            RemoteSessionView(session: session, isPresented: $showRemote)
        }
        .onChange(of: session.phase) { phase in
            if case .needPassword = phase {
                // prompt handled inside remote view
            }
            if case .failed = phase {
                // stay on sheet to show error
            }
        }
        .onChange(of: session.phase) { _ in
            promptPassword = ""
        }
    }
}
