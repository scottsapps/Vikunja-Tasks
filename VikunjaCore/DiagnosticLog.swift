import CryptoKit
import Darwin
import Foundation

/// Rolling on-device activity log, attached to bug reports the user sends
/// from Settings → Report a Bug. Every line is sanitized before it touches
/// disk — see `sanitize(_:)` — but the real defense is structural: call
/// sites must never pass user content (task titles, hosts, tokens) in the
/// first place.
///
/// One file per process kind (app / widget / watch), because several
/// processes appending to the same file corrupts it. Each file rolls off
/// its oldest 25% when it hits its cap rather than resetting, so the log is
/// always a true trailing window of activity, never a blank slate right
/// when a bug is reproduced.
enum DiagnosticLog {

    // MARK: - Public API

    static func info(_ message: String)  { write(level: "INFO ", message: message) }
    static func warn(_ message: String)  { write(level: "WARN ", message: message) }
    static func error(_ message: String) { write(level: "ERROR", message: message) }

    /// Cheap marker of "what was happening", read by `HangWatchdog` if the
    /// main thread stops responding. Just an in-memory var — never itself
    /// written to disk.
    static func breadcrumb(_ label: String) {
        breadcrumbLock.lock()
        _breadcrumb = label
        breadcrumbLock.unlock()
    }

    /// Clears the breadcrumb back to "idle", but only if `label` is still the
    /// current one — so a nested or newer operation isn't clobbered. Call at
    /// the end of anything that set one: an uncleared breadcrumb gets blamed
    /// for a hang hours later (build 62's logs reported `quickAdd.submit`
    /// against eighteen unrelated events).
    static func endBreadcrumb(_ label: String) {
        breadcrumbLock.lock()
        if _breadcrumb == label { _breadcrumb = "idle" }
        breadcrumbLock.unlock()
    }

    static var currentBreadcrumb: String {
        breadcrumbLock.lock()
        defer { breadcrumbLock.unlock() }
        return _breadcrumb
    }

    // MARK: - Suspension tracking

    /// Bumped whenever the process is detected to have been frozen — iOS
    /// suspending a backgrounded app, or macOS system sleep. `HangWatchdog`
    /// is the detector (it notices that its own 1 s timer missed ticks);
    /// this counter is what lets everything else tell a slow operation from
    /// a suspended one.
    ///
    /// Only bumped in app processes — widget extensions have no watchdog, but
    /// they're short-lived and killed rather than frozen mid-request.
    static var suspensionEpoch: Int {
        suspensionLock.lock()
        defer { suspensionLock.unlock() }
        return _suspensionEpoch
    }

    static func noteSuspension() {
        suspensionLock.lock()
        _suspensionEpoch += 1
        suspensionLock.unlock()
    }

    private static var _suspensionEpoch = 0
    private static let suspensionLock = NSLock()

    /// Renders an elapsed time, or says the process was frozen instead of
    /// printing fiction. Durations come from `Date()`, which keeps counting
    /// while a process is suspended, so an iOS app frozen mid-refresh
    /// produced lines like `GET /api/v1/labels (1852.2 s)` and even
    /// `refresh ok: … 2039.0 s` for a refresh that actually took a second.
    /// Pass the `suspensionEpoch` captured when the operation started.
    static func elapsedDescription(since start: Date, epoch: Int) -> String {
        guard epoch == suspensionEpoch else { return "app suspended during" }
        let seconds = Date().timeIntervalSince(start)
        return seconds < 1
            ? String(format: "%.0f ms", seconds * 1000)
            : String(format: "%.1f s", seconds)
    }

    /// Every log file this process can see (its own, plus any sibling files
    /// in the same App Group container), concatenated with a
    /// `--- <filename> ---` separator before each. This is what gets
    /// attached to a bug-report email.
    static func bundledLogData() -> Data {
        queue.sync {
            var combined = Data()
            for name in knownLogFileNames {
                let url = logsDirectory.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
                combined.append("--- \(name) ---\n".data(using: .utf8) ?? Data())
                combined.append(data)
                combined.append("\n".data(using: .utf8) ?? Data())
            }
            return combined
        }
    }

    /// Last ~2,000 lines of the bundled log, for the in-app viewer — full
    /// rendering of the uncapped text can hitch the UI.
    static func viewerText() -> String {
        let text = String(data: bundledLogData(), encoding: .utf8) ?? ""
        guard !text.isEmpty else { return "(Log is empty.)" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let maxLines = 2000
        guard lines.count > maxLines else { return text }
        let tail = lines.suffix(maxLines).joined(separator: "\n")
        return "(older lines truncated — the emailed attachment has everything)\n\n" + tail
    }

    static func bundledByteCount() -> Int {
        bundledLogData().count
    }

    /// Installs a last-gasp uncaught-exception handler and signal handlers.
    /// App targets only (macOS + iOS) — call once from the app's init.
    /// Calling non-async-signal-safe code (as this does) from a signal
    /// handler is technically undefined behavior; this is best-effort, and
    /// must never make a crash worse — hence no allocation-heavy work beyond
    /// the write itself. Matches SCOTUSWatch's approach.
    static func registerCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.joined(separator: "\n")
            DiagnosticLog.error("uncaught exception: \(exception.name.rawValue): \(exception.reason ?? "no reason")\n\(stack)")
            DiagnosticLog.flushSync()
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(sig) { signum in
                let name: String
                switch signum {
                case SIGABRT: name = "SIGABRT"
                case SIGSEGV: name = "SIGSEGV"
                case SIGBUS:  name = "SIGBUS"
                case SIGILL:  name = "SIGILL"
                case SIGFPE:  name = "SIGFPE"
                default:      name = "SIG\(signum)"
                }
                DiagnosticLog.error("terminated by signal \(name)")
                DiagnosticLog.flushSync()
                signal(signum, SIG_DFL)
                raise(signum)
            }
        }
    }

    /// Best-effort drain, used by the crash handlers before the process dies.
    static func flushSync() {
        queue.sync {}
    }

    /// Rewrites the header block of an existing log file in place, keeping the
    /// body and the original `Started:` time. Call once at app launch.
    ///
    /// Without this the header is a snapshot from whenever the file was
    /// created and never changes again — which in the first real logs meant a
    /// build-61 app reporting `Veyrn 2.8.0 (60)`, the version being the first
    /// thing anyone reads in a bug report. It also leaves `Accounts:` and
    /// `Server:` frozen; the server version in particular is never known at
    /// file-creation time (the `/info` fetch lands seconds later), so it read
    /// `Vikunja unknown` forever. Re-stamping at launch picks up the value
    /// cached by the previous session.
    /// Safe to call often — it rewrites only when the header would actually
    /// change, so the widget extension can call it on every timeline request
    /// without churning the file. (Build 62 re-stamped the app's header at
    /// launch but never the widget's, which kept reporting `(60)` and
    /// `Vikunja unknown` indefinitely.)
    static func refreshHeader() {
        queue.async {
            let url = currentURL
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8),
                  let terminator = text.range(of: headerTerminator)
            else { return }

            // buildHeader() reads `Started:` back out of the file on disk, so
            // it must run before the rewrite.
            let header = buildHeader()
            let existingHeader = String(text[..<terminator.upperBound])
            guard !headersMatch(existingHeader, header) else { return }

            var body = String(text[terminator.upperBound...])
            while body.hasPrefix("\n") { body.removeFirst() }

            guard let combined = (header + body).data(using: .utf8) else { return }
            try? combined.write(to: url, options: .atomic)
            approxSize = combined.count
        }
    }

    /// Compares everything but `Started:`, which is preserved across
    /// re-stamps and so always matches anyway.
    private static func headersMatch(_ a: String, _ b: String) -> Bool {
        func significant(_ s: String) -> [String] {
            s.split(separator: "\n").filter { !$0.hasPrefix("Started:") }.map(String.init)
        }
        return significant(a) == significant(b)
    }

    private static let headerTerminator = "============================\n"

    // MARK: - Process identity

    private enum ProcessKind: String {
        case app, widget, watch
    }

    private static let processKind: ProcessKind = {
        #if os(watchOS)
        return .watch
        #else
        return Bundle.main.bundleURL.pathExtension == "appex" ? .widget : .app
        #endif
    }()

    private static var logFileName: String {
        switch processKind {
        case .app: return "veyrn-app.log"
        case .widget: return "veyrn-widget.log"
        case .watch: return "veyrn-watch.log"
        }
    }

    private static var capBytes: Int {
        switch processKind {
        case .app: return 512 * 1024
        case .widget: return 256 * 1024
        case .watch: return 128 * 1024
        }
    }

    private static let knownLogFileNames = ["veyrn-app.log", "veyrn-widget.log", "veyrn-watch.log"]

    // MARK: - Storage

    private static let queue = DispatchQueue(label: "net.angstreich.veyrn.diagnosticlog")

    /// App Group (not Application Support) so the app can read the widget
    /// extension's log too — both processes share the same container.
    static let logsDirectory: URL = {
        let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: VikunjaConfig.appGroupSuite)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dirCopy = dir
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? dirCopy.setResourceValues(rv)
        return dir
    }()

    private static var currentURL: URL { logsDirectory.appendingPathComponent(logFileName) }

    // MARK: - Write

    private static func write(level: String, message: String) {
        let sanitized = sanitize(message)
        let line = "\(timestamp())  \(level)  \(sanitized)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            appendAndMaybeTrim(data)
        }
    }

    /// Tracked in-memory so a per-line file stat isn't needed — only an
    /// initial stat (first write in the process) and one more after a trim.
    private static var approxSize: Int?

    private static func appendAndMaybeTrim(_ data: Data) {
        let url = currentURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            let header = buildHeader()
            let combined = (header.data(using: .utf8) ?? Data()) + data
            try? combined.write(to: url, options: .atomic)
            excludeFromBackup(url)
            approxSize = combined.count
            return
        }
        if approxSize == nil {
            approxSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
            approxSize = (approxSize ?? 0) + data.count
        }
        if let size = approxSize, size >= capBytes {
            trim()
        }
    }

    // MARK: - Trim (oldest entries roll off — the log never resets)

    private static func trim() {
        let url = currentURL
        guard let data = try? Data(contentsOf: url) else { return }

        let keepBytes = Int(Double(data.count) * 0.75)
        let dropBytes = max(0, data.count - keepBytes)

        var startIndex = min(dropBytes, data.count)
        if startIndex < data.count, let newlineIndex = data[startIndex...].firstIndex(of: 0x0A) {
            startIndex = min(newlineIndex + 1, data.count)
        }
        let tail = data[startIndex...]

        var combined = Data()
        combined.append((buildHeader()).data(using: .utf8) ?? Data())
        combined.append("--- older entries trimmed at \(timestamp()) ---\n".data(using: .utf8) ?? Data())
        combined.append(tail)

        try? combined.write(to: url, options: .atomic)
        approxSize = combined.count
    }

    private static func excludeFromBackup(_ url: URL) {
        var u = url
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
    }

    // MARK: - Header

    /// The original creation time of the current file, preserved across
    /// trims (and process restarts, by reading it back out of an existing
    /// file's header) so "Started" always reflects true file age rather
    /// than the last trim.
    private static var cachedGenesis: String?

    private static func genesisTimestampString() -> String {
        if let cached = cachedGenesis { return cached }
        if let existing = try? String(contentsOf: currentURL, encoding: .utf8),
           let range = existing.range(of: "Started:  ") {
            let rest = existing[range.upperBound...]
            if let lineEnd = rest.firstIndex(of: "\n") {
                let value = String(rest[..<lineEnd]).trimmingCharacters(in: .whitespaces)
                cachedGenesis = value
                return value
            }
        }
        let now = timestamp()
        cachedGenesis = now
        return now
    }

    private static func buildHeader() -> String {
        let (shortVersion, build) = appVersionAndBuild()
        let tz = TimeZone.current
        let offsetSecs = tz.secondsFromGMT()
        let offsetStr = String(format: "UTC%+03d:%02d", offsetSecs / 3600, abs(offsetSecs % 3600) / 60)

        return """
        === Veyrn diagnostic log ===
        App:      Veyrn \(shortVersion) (\(build))  [\(processKind.rawValue)]
        Platform: \(platformDescription())
        Locale:   \(Locale.current.identifier)    Timezone: \(tz.identifier) (\(offsetStr))
        Accounts: \(accountsDescription())
        Server:   \(serverDescription())
        Started:  \(genesisTimestampString())
        ============================

        """
    }

    /// Non-private so `BugReportMail` can stamp the same app version/build
    /// into a report sent *without* the log — one source of truth for both.
    static func appVersionAndBuild() -> (String, String) {
        // CFBundleGetValueForInfoDictionaryKey, not Bundle.main — Bundle.main
        // is @MainActor-isolated in this context, and this can be called from
        // any thread (the serial log queue).
        let bundle = CFBundleGetMainBundle()
        let version = (CFBundleGetValueForInfoDictionaryKey(bundle, "CFBundleShortVersionString" as CFString) as? String) ?? "?"
        let build = (CFBundleGetValueForInfoDictionaryKey(bundle, kCFBundleVersionKey) as? String) ?? "?"
        return (version, build)
    }

    /// "macOS 15.7.5 (24G410)" — shared with `BugReportMail`'s message body,
    /// which doesn't want the device model or the header's "build" word.
    static func osNameVersionBuild() -> String {
        let osVer = ProcessInfo.processInfo.operatingSystemVersion
        let versionStr = "\(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)"
        let osBuild = sysctlString("kern.osversion") ?? "?"
        #if os(macOS)
        let osName = "macOS"
        #elseif os(watchOS)
        let osName = "watchOS"
        #else
        let osName = "iOS"
        #endif
        return "\(osName) \(versionStr) (\(osBuild))"
    }

    private static func platformDescription() -> String {
        let osVer = ProcessInfo.processInfo.operatingSystemVersion
        let versionStr = "\(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)"
        let osBuild = sysctlString("kern.osversion") ?? "?"
        #if os(macOS)
        let osName = "macOS"
        let model = sysctlString("hw.model") ?? "?"
        #elseif os(watchOS)
        let osName = "watchOS"
        let model = utsnameMachine()
        #else
        let osName = "iOS"
        let model = utsnameMachine()
        #endif
        return "\(osName) \(versionStr) (build \(osBuild)) / \(model)"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &value, &size, nil, 0)
        return String(cString: value)
    }

    private static func utsnameMachine() -> String {
        var info = utsname()
        uname(&info)
        let scalars = Mirror(reflecting: info.machine).children.compactMap { element -> Character? in
            guard let value = element.value as? Int8, value != 0 else { return nil }
            return Character(UnicodeScalar(UInt8(value)))
        }
        return String(scalars)
    }

    /// Count and active position only — never account names or hosts.
    private static func accountsDescription() -> String {
        let accounts = VikunjaConfig.accounts
        guard !accounts.isEmpty else { return "0" }
        if let activeId = VikunjaConfig.activeAccountId,
           let index = accounts.firstIndex(where: { $0.id == activeId }) {
            return "\(accounts.count) (active #\(index + 1))"
        }
        return "\(accounts.count)"
    }

    /// Server kind (derived by comparing against the known Cloud host —
    /// never the host itself) plus the parsed version cached by
    /// `VeyrnTelemetry` in the App Group, so a junk/hostile server string
    /// can never reach the log raw.
    private static func serverDescription() -> String {
        let kind = (!VikunjaConfig.host.isEmpty && VikunjaConfig.host == VikunjaConfig.vikunjaCloudHost)
            ? "cloud" : "custom"
        let defaults = UserDefaults(suiteName: VikunjaConfig.appGroupSuite)
        guard let version = defaults?.string(forKey: serverVersionDefaultsKey) else {
            return "\(kind) · Vikunja unknown · API v2 available: unknown"
        }
        let supportsV2 = defaults?.bool(forKey: serverSupportsV2DefaultsKey) ?? false
        return "\(kind) · Vikunja \(version) · API v2 available: \(supportsV2 ? "yes" : "no")"
    }

    /// Shared with `VeyrnTelemetry`, which writes these two keys whenever
    /// `/info` succeeds so the header can read them without a network call.
    static let serverVersionDefaultsKey = "diag.serverVersion"
    static let serverSupportsV2DefaultsKey = "diag.serverSupportsV2"

    // MARK: - Breadcrumb storage

    private static var _breadcrumb = "idle"
    private static let breadcrumbLock = NSLock()

    // MARK: - Timestamp

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()
    private static let timestampLock = NSLock()

    private static func timestamp() -> String {
        timestampLock.lock()
        defer { timestampLock.unlock() }
        return timestampFormatter.string(from: Date())
    }

    // MARK: - Sanitize (safety net — call sites must never pass user content)

    static func sanitize(_ message: String) -> String {
        var result = message

        let host = VikunjaConfig.host
        if !host.isEmpty {
            result = result.replacingOccurrences(of: host, with: "<host>")
            if let bareHost = URL(string: host)?.host {
                result = result.replacingOccurrences(of: bareHost, with: "<host>")
            }
        }
        // Peek-only: never triggers a fresh Keychain read. `apiToken` would —
        // and `TokenStore.token(for:)` itself logs on a failed read, which
        // would recurse right back into this function. See
        // `VikunjaConfig.cachedTokenIfAvailable`.
        if let token = VikunjaConfig.cachedTokenIfAvailable, !token.isEmpty {
            result = result.replacingOccurrences(of: token, with: "<token>")
        }

        result = replacing(urlPattern, in: result, with: "<url>")
        result = replacing(emailPattern, in: result, with: "<email>")
        result = redactLongRuns(in: result)

        return result
    }

    // Compiled once. `sanitize` runs on the calling thread of every log call —
    // often the main thread — so rebuilding these per line was pure waste in
    // exactly the code paths this feature exists to keep responsive.
    private static let urlPattern = try! NSRegularExpression(pattern: "https?://\\S+")
    private static let emailPattern = try! NSRegularExpression(pattern: "\\S+@\\S+\\.[A-Za-z]{2,}")

    private static func replacing(_ regex: NSRegularExpression, in text: String, with replacement: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    private static let longRunPattern = try! NSRegularExpression(pattern: "[A-Za-z0-9+/=_\\-]{21,}")

    /// Any remaining token-like run of 21+ characters (also catches UUIDs,
    /// which is why accounts are logged by index rather than id) — except a
    /// URL path, see `isSafeAPIPath(_:)`.
    private static func redactLongRuns(in text: String) -> String {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var result = text
        let matches = longRunPattern.matches(in: text, range: range)
        for match in matches.reversed() {
            let matched = ns.substring(with: match.range)
            if isSafeAPIPath(matched) { continue }
            let hash = sha256Prefix8(matched)
            if let r = Range(match.range, in: result) {
                result.replaceSubrange(r, with: "[REDACTED:\(hash)]")
            }
        }
        return result
    }

    /// `/` is in the pattern above, so an API path is just a long run of
    /// path-safe characters as far as it's concerned — and `/api/v1/projects/12/tasks`
    /// is 25 characters, so it used to be hashed away, destroying the most
    /// useful field on exactly the lines that matter (`✗ URLError(-1001) GET
    /// [REDACTED:f95b1154]`). Paths are safe by construction: `VikunjaAPI.send(_:)`
    /// logs `url.path` only, with the query stripped, and paths carry ids —
    /// never titles, names, or search text.
    ///
    /// Only whole paths are exempted, and only when every `/`-separated
    /// segment is itself short — so a secret that ever ends up *in* a path
    /// segment is still caught, as is any long run that doesn't start with
    /// `/` (a bare base64 blob containing slashes still matches in full).
    private static func isSafeAPIPath(_ candidate: String) -> Bool {
        guard candidate.hasPrefix("/") else { return false }
        return candidate.split(separator: "/").allSatisfy { $0.count < 21 }
    }

    private static func sha256Prefix8(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).lowercased()
    }
}
