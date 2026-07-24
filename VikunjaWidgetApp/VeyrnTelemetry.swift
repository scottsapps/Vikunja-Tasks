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

    // MARK: - Account switching

    /// Bucketed count only — never account names or hosts.
    static func accountSwitched(accountCount: Int) {
        signal("AccountSwitched", parameters: ["accountCount": String(accountCount)])
    }

    // MARK: - Server version reporting

    private static var hasReportedServerThisLaunch = false

    /// Called on every account switch so the newly-active server's version
    /// gets reported too — otherwise only the launch account's version is
    /// ever seen, skewing the v1→v2 migration data.
    static func resetServerInfoGuard() {
        hasReportedServerThisLaunch = false
    }

    /// Fetches the server version and reports it once per launch.
    /// Silent on network failure; safe to call from any refresh path.
    static func reportServerInfoIfNeeded() async {
        guard !hasReportedServerThisLaunch else { return }
        guard VikunjaConfig.telemetryOptIn, VikunjaConfig.isConfigured else { return }
        guard let info = try? await VikunjaAPI.fetchServerInfo() else { return }

        hasReportedServerThisLaunch = true

        let parsed = parseVersion(info.version)
        signal("ServerInfo", parameters: [
            "serverVersion": parsed.full,       // "2.4.0" | "unparseable"
            "serverMinor": parsed.minor,        // "2.4"   | "unparseable"
            "supportsApiV2": parsed.supportsV2 ? "true" : "false",
            "serverKind": VikunjaConfig.host == VikunjaConfig.vikunjaCloudHost
                ? "cloud" : "custom",
        ])
    }

    /// Parses "v2.4.0" / "2.4.0" into bounded, server-independent values.
    /// Anything else (dev builds like "unstable", git hashes, junk) → "unparseable".
    static func parseVersion(_ raw: String) -> (full: String, minor: String, supportsV2: Bool) {
        let stripped = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        // Tolerate suffixes like "2.4.0-rc1" by taking the leading numeric core.
        let core = stripped.prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 3, parts.allSatisfy({ (0...999).contains($0) }) else {
            return ("unparseable", "unparseable", false)
        }
        let (major, minor, patch) = (parts[0], parts[1], parts[2])
        let supportsV2 = (major, minor) >= (2, 4)   // v2 API landed in Vikunja 2.4.0
        return ("\(major).\(minor).\(patch)", "\(major).\(minor)", supportsV2)
    }
}
