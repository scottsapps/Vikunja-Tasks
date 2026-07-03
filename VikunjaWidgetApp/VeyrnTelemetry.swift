import Foundation
import TelemetryDeck

/// Thin wrapper around TelemetryDeck that enforces the opt-in toggle.
/// Never pass task titles, IDs, usernames, or any free text — categorical parameters only.
enum VeyrnTelemetry {
    static func initialize() {
        // App ID is for Veyrn specifically (not shared with SCOTUSWatch).
        // TelemetryDeck 2.x: verify the exact namespace property name against the SDK README.
        let config = TelemetryDeck.Config(appID: "5C1C6525-EC34-4D78-99A4-FCB2421B1E29")
        config.defaultParameters = { ["namespace": "net.angstreich.scottsapps"] }
        TelemetryDeck.initialize(config: config)
    }

    static func signal(_ name: String, parameters: [String: String] = [:]) {
        guard VikunjaConfig.telemetryOptIn else { return }
        TelemetryDeck.signal(name, parameters: parameters)
    }
}
