import SwiftUI
import UserNotifications
#if os(macOS)
import AppKit
#endif
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
        DiagnosticLog.registerCrashHandlers()
        // Before the first line of this session, so the environment block at
        // the top of the file describes the build that's actually running.
        DiagnosticLog.refreshHeader()
        HangWatchdog.start()
        // Version and build on the launch line, not just in the header: the
        // header is re-stamped to the *current* build, so on a log spanning an
        // update it no longer describes the older entries below it (a build-62
        // header sat above entries written by 60 and 61). This makes each
        // session self-identifying.
        //
        // "background" means BGTaskScheduler woke the whole app rather than the
        // user opening it — seven of the "launches" in one iOS log were these,
        // and they read identically without the label.
        let (version, build) = DiagnosticLog.appVersionAndBuild()
        #if os(iOS)
        let launchKind = UIApplication.shared.applicationState == .background ? "background" : "foreground"
        #else
        let launchKind = "foreground"
        #endif
        DiagnosticLog.info("app launch (\(launchKind)): Veyrn \(version) (\(build)), configured=\(VikunjaConfig.isConfigured), accounts=\(VikunjaConfig.accounts.count)")
        VikunjaConfig.cleanupOrphanedKeychainItemsIfNeeded()
        #if os(macOS)
        VikunjaConfig.registerHotkeyDefaults()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            DiagnosticLog.info("app will terminate")
            DiagnosticLog.flushSync()
        }
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
            DiagnosticLog.info("scenePhase → \(newPhase)")
            // A backgrounded (iOS: suspended) process must not be mistaken for
            // a hung one — see HangWatchdog.pause().
            if newPhase == .active { HangWatchdog.resume() } else { HangWatchdog.pause() }
            if newPhase == .active {
                Task {
                    await store.drainOutbox()
                    await store.refreshIfStale(maxAge: 60, reason: "scenePhase")
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
