import Foundation

/// Telemetry events that happen where the TelemetryDeck SDK isn't linked — the
/// widget extension's `CompleteTaskIntent` today. The extension bumps a counter
/// in the shared App Group; the app reads and clears it at launch/foreground
/// (`VeyrnTelemetry.flushExtensionCounters`) and sends the real signals.
///
/// Keys look like `analytics.pending.TaskCompleted.widget`. Categories only —
/// never a task id or title.
public enum TelemetryCounters {
    private static let prefix = "analytics.pending."

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: VikunjaConfig.appGroupSuite)
    }

    public static func increment(event: String, source: String) {
        guard let defaults else { return }
        let key = "\(prefix)\(event).\(source)"
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
    }

    /// Returns every pending counter as `(event, source, count)` and clears them.
    public static func take() -> [(event: String, source: String, count: Int)] {
        guard let defaults else { return [] }
        var out: [(String, String, Int)] = []
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count)
            let parts = rest.split(separator: ".", maxSplits: 1).map(String.init)
            let count = defaults.integer(forKey: key)
            defaults.removeObject(forKey: key)
            if parts.count == 2, count > 0 { out.append((parts[0], parts[1], count)) }
        }
        return out
    }
}
