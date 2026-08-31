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

    /// Fetches the server version once per launch (or once per account after
    /// a switch) and caches the parsed result for the diagnostic log header
    /// (`DiagnosticLog.serverVersionDefaultsKey`/`serverSupportsV2DefaultsKey`
    /// in the App Group, so the widget extension's header can read it too).
    ///
    /// Renamed from `reportServerInfoIfNeeded` (was gated on
    /// `telemetryOptIn` before the fetch, so a user with analytics off had no
    /// server version in their diagnostic log). The fetch is now gated on
    /// `isConfigured` only — the version is non-identifying, stays on-device,
    /// and only leaves if the user attaches the log themselves. Only the
    /// TelemetryDeck *signal* stays behind the opt-in.
    static func probeServerInfoIfNeeded() async {
        guard !hasReportedServerThisLaunch else { return }
        guard VikunjaConfig.isConfigured else { return }
        guard let info = try? await VikunjaAPI.fetchServerInfo() else { return }

        hasReportedServerThisLaunch = true

        let parsed = parseVersion(info.version)
        let kind = VikunjaConfig.host == VikunjaConfig.vikunjaCloudHost ? "cloud" : "custom"

        let diagDefaults = UserDefaults(suiteName: VikunjaConfig.appGroupSuite)
        diagDefaults?.set(parsed.full, forKey: DiagnosticLog.serverVersionDefaultsKey)
        diagDefaults?.set(parsed.supportsV2, forKey: DiagnosticLog.serverSupportsV2DefaultsKey)
        diagDefaults?.set(parsed.supportsBulkCreate, forKey: DiagnosticLog.serverSupportsBulkCreateDefaultsKey)
        diagDefaults?.set(parsed.supportsDefaultDueTime, forKey: DiagnosticLog.serverSupportsDefaultDueTimeDefaultsKey)
        DiagnosticLog.info("server: \(kind) · Vikunja \(parsed.full) · API v2 available: \(parsed.supportsV2 ? "yes" : "no")"
                           + " · bulk create: \(parsed.supportsBulkCreate ? "yes" : "no")"
                           + " · default due time setting: \(parsed.supportsDefaultDueTime ? "yes" : "no")")

        guard VikunjaConfig.telemetryOptIn else { return }
        signal("ServerInfo", parameters: [
            "serverVersion": parsed.full,       // "2.4.0" | "unparseable"
            "serverMinor": parsed.minor,        // "2.4"   | "unparseable"
            "supportsApiV2": parsed.supportsV2 ? "true" : "false",
            "supportsBulkCreate": parsed.supportsBulkCreate ? "true" : "false",
            "supportsDefaultDueTime": parsed.supportsDefaultDueTime ? "true" : "false",
            "serverKind": kind,
        ])
    }

    /// Parses "v2.4.0" / "2.4.0" into bounded, server-independent values.
    /// Anything else (dev builds like "unstable", git hashes, junk) → "unparseable".
    static func parseVersion(_ raw: String) -> (full: String, minor: String, supportsV2: Bool, supportsBulkCreate: Bool, supportsDefaultDueTime: Bool) {
        let stripped = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        // Tolerate suffixes like "2.4.0-rc1" by taking the leading numeric core.
        let core = stripped.prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 3, parts.allSatisfy({ (0...999).contains($0) }) else {
            return ("unparseable", "unparseable", false, false, false)
        }
        let (major, minor, patch) = (parts[0], parts[1], parts[2])
        let supportsV2 = (major, minor) >= (2, 4)          // v2 API landed in Vikunja 2.4.0
        let supportsBulk = (major, minor) >= (2, 5)        // bulk task creation landed in 2.5.0
        let supportsDueTime = (major, minor) >= (2, 6)     // default due time setting landed in 2.6.0
        return ("\(major).\(minor).\(patch)", "\(major).\(minor)", supportsV2, supportsBulk, supportsDueTime)
    }
}
