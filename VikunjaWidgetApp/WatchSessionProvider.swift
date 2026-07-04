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

    func session(_ s: WCSession, activationDidCompleteWith _: WCSessionActivationState, error _: Error?) {
        syncConfig()
    }
    func sessionReachabilityDidChange(_ s: WCSession) { syncConfig() }
    func sessionDidBecomeInactive(_ s: WCSession) {}
    func sessionDidDeactivate(_ s: WCSession) { WCSession.default.activate() }
}
#endif
