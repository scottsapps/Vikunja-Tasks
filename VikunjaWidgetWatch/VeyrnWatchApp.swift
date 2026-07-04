import SwiftUI

@main
struct VeyrnWatchApp: App {
    @StateObject private var config = WatchConfigStore.shared
    @State private var store = WatchStore()
    @Environment(\.scenePhase) private var scenePhase

    init() { WatchConfigStore.shared.activate() }

    var body: some Scene {
        WindowGroup {
            if config.isConfigured {
                WatchRootView(store: store)
            } else {
                NeedsSetupView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning to the app (not just a cold launch) re-fetches, so the
            // list never shows a stale snapshot after tasks change elsewhere.
            if phase == .active {
                store.loadFromCache()
                Task { await store.refresh() }
            }
        }
    }
}
