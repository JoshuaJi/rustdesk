import SwiftUI

@main
struct JoshuaRustDeskApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var bridge = RustDeskBridge.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bridge)
                .tint(.white)
                // White accents need a dark chrome; remote UI is already black.
                .preferredColorScheme(.dark)
                .onAppear {
                    bridge.bootstrap()
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var bridge: RustDeskBridge
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            HomeView()
                // Document-picker home: title lives in the grid header on iPad;
                // on iPhone the in-body “Connections” title is enough.
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if hSize != .compact {
                        ToolbarItem(placement: .principal) {
                            Text("RustDesk")
                                .font(.headline)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                .sheet(isPresented: $showSettings) {
                    NavigationStack {
                        SettingsView()
                            .environmentObject(bridge)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done") { showSettings = false }
                                }
                            }
                    }
                    // Ensure sheet controls are interactive (Form pickers/toggles).
                    .environmentObject(bridge)
                    .tint(.white)
                    .preferredColorScheme(.dark)
                }
        }
    }
}
