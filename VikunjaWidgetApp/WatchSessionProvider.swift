#if os(iOS)
import Foundation
import WatchConnectivity

final class WatchSessionProvider: NSObject, WCSessionDelegate {
    static let shared = WatchSessionProvider()

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

    func session(_ s: WCSession, activationDidCompleteWith _: WCSessionActivationState, error _: Error?) {
        syncConfig()
    }
    func sessionReachabilityDidChange(_ s: WCSession) { syncConfig() }
    func sessionDidBecomeInactive(_ s: WCSession) {}
    func sessionDidDeactivate(_ s: WCSession) { WCSession.default.activate() }
}
#endif
