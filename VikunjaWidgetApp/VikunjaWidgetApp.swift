import SwiftUI

@main
struct VikunjaWidgetAppEntry: App {
    @State private var store = TaskStore()
    #if os(macOS)
    @State private var panelController = QuickAddPanelController()
    #endif
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppRoot(store: store)
                #if os(macOS)
                .onAppear {
                    panelController.setup(store: store)
                }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 600)
        #endif
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await store.drainOutbox() }
            }
        }
    }
}
