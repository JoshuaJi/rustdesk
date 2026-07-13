import SwiftUI

struct RemoteSessionView: View {
    @ObservedObject var session: SessionController
    @Binding var isPresented: Bool
    @State private var password = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MetalRemoteView(
                session: session,
                onSize: { size in
                    let s = UIScreen.main.scale
                    session.setViewSize(
                        width: Int(size.width * s),
                        height: Int(size.height * s)
                    )
                },
                onTouch: { json in
                    session.sendMouseJSON(json)
                }
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button {
                        session.close()
                        isPresented = false
                    } label: {
                        Label("Close", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.45), in: Capsule())
                    }
                    Spacer()
                    Text(session.statusText)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.45), in: Capsule())
                }
                .padding()
                Spacer()
            }

            if case .needPassword = session.phase {
                passwordSheet
            }

            if case .failed(let msg) = session.phase {
                VStack(spacing: 12) {
                    Text("Connection failed")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                    Button("Close") {
                        session.close()
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                .padding()
            }

            if session.phase == .connecting {
                ProgressView("Connecting…")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .padding()
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .statusBarHidden(true)
    }

    private var passwordSheet: some View {
        VStack(spacing: 12) {
            Text(session.passwordPrompt.isEmpty ? "Password required" : session.passwordPrompt)
                .foregroundStyle(.white)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            Button("Submit") {
                session.submitPassword(password)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
    }
}
