#if os(iOS)
import Foundation
import WatchConnectivity

final class WatchSessionProvider: NSObject, WCSessionDelegate {
    static let shared = WatchSessionProvider()

    private var lastPushedTodayCount: Int?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func syncConfig() {
        guard WCSession.default.activationState == .activated else { return }
        let ctx: [String: Any] = [
            "vikunja_host": VikunjaConfig.host,
            "vikunja_api_token": VikunjaConfig.apiToken,
        ]
        try? WCSession.default.updateApplicationContext(ctx)
    }

    /// Pushes the current task/project snapshot to the Watch so its Smart Stack
    /// widget stays fresh without ever opening the Watch app. `updateApplicationContext`
    /// REPLACES the previous context, so credentials must ride along with every
    /// snapshot (the watch reads host/token from this same dictionary).
    func pushSnapshot(tasks: [VikunjaTask], projects: [VikunjaProject]) {
        let session = WCSession.default
        guard WCSession.isSupported(),
              session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        guard let tasksData = try? JSONEncoder().encode(tasks),
              let projectsData = try? JSONEncoder().encode(projects) else { return }
        let ctx: [String: Any] = [
            "vikunja_host": VikunjaConfig.host,
            "vikunja_api_token": VikunjaConfig.apiToken,
            "tasks_snapshot": tasksData,
            "projects_snapshot": projectsData,
            "snapshot_at": Date().timeIntervalSince1970,
        ]
        try? session.updateApplicationContext(ctx)

        // Budgeted complication wake (~50/day): only when the number the
        // widget displays actually changed.
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let todayCount = tasks.filter {
            guard let d = $0.effectiveDueDate else { return false }
            return cal.startOfDay(for: d) <= today
        }.count
        if todayCount != lastPushedTodayCount, session.isComplicationEnabled {
            session.transferCurrentComplicationUserInfo(ctx)
        }
        lastPushedTodayCount = todayCount
    }

    /// The Watch reports a task it completed (see `WatchConfigStore.reportCompletion`).
    /// Handle it like any cross-device completion: drop this task's local
    /// reminder now (which also tombstones it against a still-stale list),
    /// nudge the Mac, and catch the widget/Watch caches up.
    func session(_ s: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let taskId = userInfo["completed_task_id"] as? Int else { return }
        DiagnosticLog.info("watch reported completion: task \(taskId)")
        Task {
            await ReminderStore.cancel(taskId: taskId, reason: "completed on watch")
            ChangeBeacon.publish(reason: "watch completion")
            try? await BackgroundRefresh.performSync(reason: "watch")
        }
    }

    func session(_ s: WCSession, activationDidCompleteWith _: WCSessionActivationState, error _: Error?) {
        syncConfig()
    }
    func sessionReachabilityDidChange(_ s: WCSession) { syncConfig() }
    func sessionDidBecomeInactive(_ s: WCSession) {}
    func sessionDidDeactivate(_ s: WCSession) { WCSession.default.activate() }
}
#endif
