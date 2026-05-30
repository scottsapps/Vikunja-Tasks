import SwiftUI

@main
struct VeyrnWatchApp: App {
    @StateObject private var config = WatchConfigStore.shared
    @State private var store = WatchStore()

    init() { WatchConfigStore.shared.activate() }

    var body: some Scene {
        WindowGroup {
            if config.isConfigured {
                WatchRootView(store: store)
            } else {
                NeedsSetupView()
            }
        }
    }
}
