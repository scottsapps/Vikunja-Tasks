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
        UIApplication.shared.registerForRemoteNotifications()
        ChangeBeacon.registerForNudges()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            guard await ChangeBeacon.shouldSync(forRemoteNotification: userInfo) else {
                completionHandler(.noData); return
            }
            do {
                // Use `performSync` rather than `store.refresh()` even when the app
                // happens to be foregrounded: a silent push can arrive with the
                // process launched into the background where `TaskStore` state isn't
                // meaningful. The foreground store catches up via the existing
                // `scenePhase → active` → `refreshIfStale(60)`.
                let count = try await BackgroundRefresh.performSync(reason: "nudge", verifyReminders: true)
                DiagnosticLog.info("nudge sync done: \(count) tasks")
                completionHandler(.newData)
            } catch {
                DiagnosticLog.warn("nudge sync failed: \(VeyrnError.logDescription(for: error))")
                completionHandler(.failed)
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        DiagnosticLog.warn("push registration failed: \(VeyrnError.logDescription(for: error))")
        ChangeBeacon.disableForSession(reason: "push registration failed")
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

#if os(macOS)
extension Notification.Name {
    static let veyrnNudgeReceived = Notification.Name("net.angstreich.VikunjaWidgetApp.nudgeReceived")
}

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
        ChangeBeacon.registerForNudges()
    }

    // On macOS the app is by definition running to receive a push, so
    // `TaskStore` *is* meaningful — hence posting for `AppRoot` to pick up
    // rather than calling `BackgroundRefresh.performSync` (which doesn't
    // exist on macOS anyway).
    func application(_ application: NSApplication,
                     didReceiveRemoteNotification userInfo: [String: Any]) {
        Task {
            guard await ChangeBeacon.shouldSync(forRemoteNotification: userInfo) else { return }
            NotificationCenter.default.post(name: .veyrnNudgeReceived, object: nil)
        }
    }

    func application(_ application: NSApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DiagnosticLog.warn("push registration failed: \(VeyrnError.logDescription(for: error))")
        ChangeBeacon.disableForSession(reason: "push registration failed")
    }
}
#endif

@main
struct VikunjaWidgetAppEntry: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) var appDelegate
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
        let (version, build) = DiagnosticLog.appVersionAndBuild()
        // The foreground/background trigger is logged separately by AppRoot:
        // UIApplication.applicationState read this early in App.init() hasn't
        // settled and reports .active even for a BGTask wake, which is how
        // build 63 logged "app launch (foreground)" one line above
        // "launched into background".
        DiagnosticLog.info("app launch: Veyrn \(version) (\(build)), configured=\(VikunjaConfig.isConfigured), accounts=\(VikunjaConfig.accounts.count)")
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
