import Darwin
import SwiftUI

if ProcessInfo.processInfo.environment["PORT_FORWARD_ASKPASS"] == "1" {
    let rawID = ProcessInfo.processInfo.environment["PORT_FORWARD_PROFILE_ID"] ?? ""
    if let id = UUID(uuidString: rawID), let password = KeychainStore.load(for: id) {
        FileHandle.standardOutput.write(Data((password + "\n").utf8))
        exit(EXIT_SUCCESS)
    }
    exit(EXIT_FAILURE)
} else {
    PortForwardStudioApp.main()
}

struct PortForwardStudioApp: App {
    @StateObject private var store: AppStore
    @StateObject private var tunnels: TunnelManager

    init() {
        let store = AppStore()
        _store = StateObject(wrappedValue: store)
        _tunnels = StateObject(wrappedValue: store.tunnels)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(tunnels)
                .frame(minWidth: 900, minHeight: 620)
                .onDisappear { tunnels.stopAll() }
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建转发") { _ = store.addProfile() }
                    .keyboardShortcut("n")
            }
        }
    }
}
