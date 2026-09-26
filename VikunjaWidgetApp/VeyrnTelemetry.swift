import Foundation
import TelemetryDeck
import EventKit
import UserNotifications
import WidgetKit
#if os(iOS)
import WatchConnectivity
#endif

/// Thin wrapper around TelemetryDeck that enforces the opt-in toggle.
/// Never pass task titles, IDs, usernames, or any free text — categorical parameters only.
enum VeyrnTelemetry {

    // MARK: - Lifecycle

    private static var didInitialize = false

    /// Starts the SDK only for a user who has opted in. The SDK sends
    /// `TelemetryDeck.Session.started` on its own the moment it initializes, so
    /// initializing for an opted-out user would still transmit — `signal(_:)`'s
    /// own opt-in check can't stop that. SCOTUSWatch behaves the same way.
    static func initialize() {
        guard VikunjaConfig.telemetryOptIn, !didInitialize else { return }
        // App ID is for Veyrn specifically (not shared with SCOTUSWatch).
        let config = TelemetryDeck.Config(appID: "5C1C6525-EC34-4D78-99A4-FCB2421B1E29")
        // A plain per-signal parameter (the SDK's own `namespace:` initializer
        // argument is a different thing — a server-side segregation we don't use).
        // Kept because it has been on every signal so far and dashboards may
        // filter on it.
        config.defaultParameters = { ["namespace": "net.angstreich.scottsapps"] }
        TelemetryDeck.initialize(config: config)
        didInitialize = true
    }

    /// Called by both privacy toggles. Turning it on starts the SDK; turning it
    /// off shuts it down so the SDK's own automatic signals stop too.
    static func setOptIn(_ on: Bool) {
        if on {
            initialize()
        } else if didInitialize {
            TelemetryDeck.terminate()
            didInitialize = false
        }
    }

    static func signal(_ name: String, parameters: [String: String] = [:]) {
        guard VikunjaConfig.telemetryOptIn, didInitialize else { return }
        TelemetryDeck.signal(name, parameters: parameters)
    }

    // MARK: - Helpers

    /// Same bands as SCOTUSWatch's `bucket()`.
    static func bucket(_ n: Int) -> String {
        switch n {
        case ..<1:     return "0"
        case 1:        return "1"
        case 2...5:    return "2-5"
        case 6...10:   return "6-10"
        case 11...20:  return "11-20"
        case 21...30:  return "21-30"
        default:       return "30+"
        }
    }

    /// Error events: at most one signal per session per (name, discriminator), so
    /// a retry loop can't flood the counts.
    private static var sentOnce = Set<String>()

    static func signalOnce(_ name: String, key: String, parameters: [String: String] = [:]) {
        guard sentOnce.insert("\(name):\(key)").inserted else { return }
        signal(name, parameters: parameters)
    }

    /// Active account's server kind — categorical, never the host.
    static var serverKind: String {
        VikunjaConfig.host == VikunjaConfig.vikunjaCloudHost ? "cloud" : "custom"
    }

    /// One classification for every failure event (`SignIn.failed`, `Sync.failed`),
    /// mirroring the alert logic in `VeyrnError`:
    /// `auth | unreachable | tls | badURL | rateLimited | other`.
    /// (`serverTooOld` is not produced: nothing in the app enforces a minimum
    /// server version, so there is no failure to classify.)
    static func failureReason(_ error: Error) -> String {
        if let api = error as? VikunjaAPI.APIError {
            if api.isAuthFailure { return "auth" }
            if api.isRateLimited { return "rateLimited" }
            if api.statusCode == 404 { return "badURL" }
            return "other"
        }
        // An answer that isn't a Vikunja API response: wrong address.
        if error is DecodingError { return "badURL" }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return "other" }
        switch ns.code {
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            return "tls"
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL:
            return "badURL"
        case NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
            return "unreachable"
        default:
            return "other"
        }
    }

    // MARK: - Account switching

    /// Sent only for a user-initiated switch between existing accounts; the other
    /// `TaskStore.SwitchReason`s (new account, host edit, deletion) are covered by
    /// `SignedIn` or don't matter. Bucketed count only — never names or hosts.
    static func accountSwitched(accountCount: Int) {
        signal("AccountSwitched", parameters: ["accountCount": String(accountCount)])
    }

    // MARK: - Sign-in funnel

    /// `context`: `firstRun` (the onboarding form) or `addAccount`.
    static func signInFormOpened(context: String) {
        signal("SignIn.formOpened", parameters: ["context": context])
    }

    /// `reason`: `duplicateName | limitReached | emptyField | badURL`. Local
    /// validation only — nothing has reached the server yet.
    static func signInFormError(reason: String) {
        signal("SignIn.formError", parameters: ["reason": reason])
    }

    /// First refresh of a brand-new account. `SignedIn` fires when the
    /// credentials are *saved*; this says whether they work.
    static func signInVerified() {
        signal("SignIn.verified", parameters: ["serverKind": serverKind])
    }

    static func signInFailed(_ error: Error) {
        signal("SignIn.failed", parameters: [
            "serverKind": serverKind,
            "reason": failureReason(error),
        ])
    }

    // MARK: - Sync failures

    /// `op`: `refresh | drain`. Callers skip connectivity-only errors — those are
    /// already treated as not-a-failure everywhere else in the app.
    static func syncFailed(op: String, error: Error) {
        let reason = failureReason(error)
        signalOnce("Sync.failed", key: "\(op):\(reason)", parameters: ["op": op, "reason": reason])
    }

    // MARK: - Extension counters

    /// Flushes what the widget extension counted (see `TelemetryCounters`) as
    /// individual signals with a `source`, capped at 25 per flush so a widget
    /// power user can't send hundreds at once. Counters are cleared either way —
    /// an opted-out user's counts are discarded, not held.
    static func flushExtensionCounters() {
        let pending = TelemetryCounters.take()
        guard VikunjaConfig.telemetryOptIn else { return }
        var budget = 25
        for item in pending {
            let n = min(item.count, budget)
            budget -= n
            for _ in 0..<n { signal(item.event, parameters: ["source": item.source]) }
            if budget == 0 { break }
        }
    }

    // MARK: - Daily snapshot

    private static let snapshotDateKey = "vikunja_telemetry_snapshot_date"

    /// Once per calendar day, from the first successful refresh (so the counts
    /// are real). Answers "does anyone use the widgets / Watch / hotkey?" with
    /// end state rather than event counts.
    static func sendDailySnapshotIfNeeded(
        accountCount: Int, projectCount: Int, openTaskCount: Int, outboxDepth: Int
    ) async {
        guard VikunjaConfig.telemetryOptIn, didInitialize else { return }
        if let last = UserDefaults.standard.object(forKey: snapshotDateKey) as? Date,
           Calendar.current.isDateInToday(last) { return }
        UserDefaults.standard.set(Date(), forKey: snapshotDateKey)

        let configs = (try? await WidgetCenter.shared.currentConfigurations()) ?? []
        func families(of kind: String) -> String {
            let set = Set(configs.filter { $0.kind == kind }.map { String(describing: $0.family) })
            return set.isEmpty ? "none" : set.sorted().joined(separator: "+")
        }
        let reminders = await UNUserNotificationCenter.current().pendingNotificationRequests()

        var params: [String: String] = [
            "widgets.tasks": families(of: "VikunjaWidget"),
            "widgets.calendar": families(of: VeyrnCalendarWidgetKind),
            "calendarAccess": calendarAccess(),
            "reminders": reminders.isEmpty ? "off" : "on",
            "accountCount": bucket(accountCount),
            "projectCount": bucket(projectCount),
            "openTaskCount": bucket(openTaskCount),
            "outboxDepth": bucket(outboxDepth),
            "serverKind": serverKind,
        ]
        #if os(iOS)
        params["watch"] = watchState()
        #endif
        #if os(macOS)
        params["quickAddHotkey"] = VikunjaConfig.quickAddKeyCode != 0 ? "on" : "off"
        #endif
        signal("App.dailySnapshot", parameters: params)
    }

    private static func calendarAccess() -> String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:    return "full"
        case .writeOnly:     return "writeOnly"
        case .denied:        return "denied"
        case .restricted:    return "restricted"
        default:             return "notDetermined"
        }
    }

    #if os(iOS)
    private static func watchState() -> String {
        guard WCSession.isSupported() else { return "none" }
        let s = WCSession.default
        if s.isWatchAppInstalled { return "appInstalled" }
        return s.isPaired ? "paired" : "none"
    }
    #endif

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
        let kind = serverKind

        let diagDefaults = UserDefaults(suiteName: VikunjaConfig.appGroupSuite)
        diagDefaults?.set(parsed.full, forKey: DiagnosticLog.serverVersionDefaultsKey)
        diagDefaults?.set(parsed.supportsV2, forKey: DiagnosticLog.serverSupportsV2DefaultsKey)
        diagDefaults?.set(parsed.supportsBulkCreate, forKey: DiagnosticLog.serverSupportsBulkCreateDefaultsKey)
        diagDefaults?.set(parsed.supportsDefaultDueTime, forKey: DiagnosticLog.serverSupportsDefaultDueTimeDefaultsKey)
        DiagnosticLog.info("server: \(kind) · Vikunja \(parsed.full) · API v2 available: \(parsed.supportsV2 ? "yes" : "no")"
                           + " · bulk create: \(parsed.supportsBulkCreate ? "yes" : "no")"
                           + " · default due time setting: \(parsed.supportsDefaultDueTime ? "yes" : "no")")

        guard VikunjaConfig.telemetryOptIn, shouldSignalServerInfoToday() else { return }
        signal("ServerInfo", parameters: [
            "serverVersion": parsed.full,       // "2.4.0" | "unparseable"
            "serverMinor": parsed.minor,        // "2.4"   | "unparseable"
            "supportsApiV2": parsed.supportsV2 ? "true" : "false",
            "supportsBulkCreate": parsed.supportsBulkCreate ? "true" : "false",
            "supportsDefaultDueTime": parsed.supportsDefaultDueTime ? "true" : "false",
            "serverKind": kind,
        ])
    }

    /// The diagnostic-log defaults above update on every probe (on-device only);
    /// the TelemetryDeck signal goes at most once a day per account. The account
    /// UUID stays in UserDefaults on this device — it is never put in the signal.
    private static let serverInfoSignalKey = "vikunja_telemetry_server_info_signal"

    private static func shouldSignalServerInfoToday() -> Bool {
        guard let id = VikunjaConfig.activeAccountId?.uuidString else { return true }
        var stamps = UserDefaults.standard.dictionary(forKey: serverInfoSignalKey) as? [String: Date] ?? [:]
        if let last = stamps[id], Calendar.current.isDateInToday(last) { return false }
        stamps[id] = Date()
        UserDefaults.standard.set(stamps, forKey: serverInfoSignalKey)
        return true
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
