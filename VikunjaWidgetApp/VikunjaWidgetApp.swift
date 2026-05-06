import SwiftUI
#if os(iOS)
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        if let item = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            route(item)
            return false
        }
        return true
    }

    func application(_ application: UIApplication,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        route(shortcutItem)
        completionHandler(true)
    }

    private func route(_ item: UIApplicationShortcutItem) {
        let action: ShortcutRouter.ShortcutAction
        switch item.type {
        case "net.angstreich.VikunjaWidgetApp.NewTask": action = .newTask
        case "net.angstreich.VikunjaWidgetApp.Today":   action = .today
        default: return
        }
        ShortcutRouter.shared.pendingAction = action
        // Post so onReceive fires even if onChange misses the transition window
        NotificationCenter.default.post(name: .vikunjaShortcutFired, object: nil)
    }
}
#endif

@main
struct VikunjaWidgetAppEntry: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
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
