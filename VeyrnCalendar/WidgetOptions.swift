//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/WidgetOptions.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.

import Foundation

/// The widget's non-calendar settings: how far ahead to look, and whether to include
/// all-day and declined events. The widget has no configuration sheet — these are edited
/// in the app (§11) and read by the provider from the App Group.
public struct WidgetOptions: Codable, Sendable, Equatable {
    /// Fetch horizon in days. Clamp with `effectiveDaysAhead` before use — it must cover
    /// two widget pages.
    public var daysAhead: Int
    /// Include all-day events (default true).
    public var showAllDay: Bool
    /// Include events the current user has declined. Default true: they appear dimmed with
    /// a gear glyph; off hides them entirely.
    public var showDeclined: Bool

    public static let `default` = WidgetOptions(daysAhead: 14, showAllDay: true, showDeclined: true)

    /// The sensible editing range for `daysAhead` (a stepper in the app binds to this).
    public static let daysAheadRange = 3...60

    public init(daysAhead: Int = 14, showAllDay: Bool = true, showDeclined: Bool = true) {
        self.daysAhead = daysAhead
        self.showAllDay = showAllDay
        self.showDeclined = showDeclined
    }

    /// `daysAhead` clamped to something the layout can actually page through.
    public var effectiveDaysAhead: Int {
        min(WidgetOptions.daysAheadRange.upperBound, max(2, daysAhead))
    }
}

/// Reads and writes `WidgetOptions` in the App Group (like `CalendarSelectionStore`).
public enum WidgetOptionsStore {
    /// Veyrn's App Group, not Calvane's — see `CalendarSelectionStore.appGroup`.
    public static var appGroup: String { VikunjaConfig.appGroupSuite }
    /// Namespaced on the move into Veyrn: this suite now holds task keys too.
    static let key = "calendar.widgetOptions.v1"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// The stored options, or `.default` when nothing has been saved (or it fails to decode).
    public static func load() -> WidgetOptions {
        guard let data = defaults?.data(forKey: key),
              let decoded = try? JSONDecoder().decode(WidgetOptions.self, from: data)
        else { return .default }
        return decoded
    }

    public static func save(_ options: WidgetOptions) {
        guard let data = try? JSONEncoder().encode(options) else { return }
        defaults?.set(data, forKey: key)
    }
}
