import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundRefresh.register()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem {
            ShortcutRouting.route(item)
        }
    }

    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        ShortcutRouting.route(shortcutItem)
        completionHandler(true)
    }
}

enum ShortcutRouting {
    static func route(_ item: UIApplicationShortcutItem) {
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

    init() {
        VeyrnTelemetry.initialize()
        #if os(macOS)
        VikunjaConfig.registerHotkeyDefaults()
        #endif
        #if os(iOS)
        WatchSessionProvider.shared.activate()
        #endif
        UNUserNotificationCenter.current().delegate = NotificationResponseHandler.shared
        ReminderScheduler.registerCategory()
    }

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
                Task {
                    await store.drainOutbox()
                    await store.refreshIfStale(maxAge: 60)
                }
            }
            #if os(iOS)
            if newPhase == .background {
                BackgroundRefresh.schedule()
            }
            #endif
        }
    }
}
