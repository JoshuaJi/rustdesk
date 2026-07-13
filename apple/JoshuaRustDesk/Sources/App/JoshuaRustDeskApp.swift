import SwiftUI

@main
struct JoshuaRustDeskApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var bridge = RustDeskBridge.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bridge)
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
                .navigationTitle("RustDesk")
                .toolbar {
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
