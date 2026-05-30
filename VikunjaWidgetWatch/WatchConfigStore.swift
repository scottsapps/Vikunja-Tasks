import Foundation
import WatchConnectivity

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
        DispatchQueue.main.async { self.isConfigured = VikunjaConfig.isConfigured }
    }

    func session(_ s: WCSession, activationDidCompleteWith _: WCSessionActivationState, error _: Error?) {
        let ctx = WCSession.default.receivedApplicationContext
        if !ctx.isEmpty { store(ctx) }
    }

    func session(_ s: WCSession, didReceiveApplicationContext ctx: [String: Any]) { store(ctx) }
}
