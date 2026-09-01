import Foundation
import WatchConnectivity
import WidgetKit

final class WatchConfigStore: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchConfigStore()

    @Published var isConfigured = VikunjaConfig.isConfigured

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Tell the phone a task was completed here. The Watch schedules no
    /// notifications of its own, but the phone's local reminder — mirrored to
    /// this Watch whenever the phone is locked — would otherwise fire for a
    /// task finished on the wrist, and the phone only learns of it through the
    /// `filter=done=false` list, which has been seen to lag by many minutes.
    /// `transferUserInfo` is queued, background-delivered, and survives the
    /// phone being unreachable right now.
    func reportCompletion(taskId: Int) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo(["completed_task_id": taskId])
    }

    private func store(_ ctx: [String: Any]) {
        let defaults = UserDefaults(suiteName: VikunjaConfig.appGroupSuite)
        if let host = ctx["vikunja_host"] as? String { defaults?.set(host, forKey: "vikunja_host") }
        if let token = ctx["vikunja_api_token"] as? String {
            // The Watch has its own separate Keychain (a separate device) —
            // WatchConnectivity is unchanged, only where the received token
            // lands locally changes.
            TokenStore.setToken(token, for: VikunjaConfig.watchTokenAccountId)
            VikunjaConfig.invalidateTokenCache()
        }
        if let tasksData = ctx["tasks_snapshot"] as? Data,
           let projectsData = ctx["projects_snapshot"] as? Data,
           let tasks = try? JSONDecoder().decode([VikunjaTask].self, from: tasksData),
           let projects = try? JSONDecoder().decode([VikunjaProject].self, from: projectsData) {
            WidgetCache.save(tasks: tasks, projects: projects)
            WidgetCenter.shared.reloadAllTimelines()
        }
        DispatchQueue.main.async { self.isConfigured = VikunjaConfig.isConfigured }
    }

    func session(_ s: WCSession, activationDidCompleteWith _: WCSessionActivationState, error _: Error?) {
        let ctx = WCSession.default.receivedApplicationContext
        if !ctx.isEmpty { store(ctx) }
    }

    func session(_ s: WCSession, didReceiveApplicationContext ctx: [String: Any]) { store(ctx) }

    // Arrives via `transferCurrentComplicationUserInfo` on the phone.
    func session(_ s: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) { store(userInfo) }
}
