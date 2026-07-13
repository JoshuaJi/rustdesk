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
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            HomeView()
                // Document-picker home: title lives in the grid header, not the nav bar.
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text("RustDesk")
                            .font(.headline)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .sheet(isPresented: $showSettings) {
                    NavigationStack {
                        SettingsView()
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done") { showSettings = false }
                                }
                            }
                    }
                }
        }
    }
}
