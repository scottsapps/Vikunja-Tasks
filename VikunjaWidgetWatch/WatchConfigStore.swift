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

    private func store(_ ctx: [String: Any]) {
        let defaults = UserDefaults(suiteName: VikunjaConfig.appGroupSuite)
        if let host = ctx["vikunja_host"] as? String { defaults?.set(host, forKey: "vikunja_host") }
        if let token = ctx["vikunja_api_token"] as? String { defaults?.set(token, forKey: "vikunja_api_token") }
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
