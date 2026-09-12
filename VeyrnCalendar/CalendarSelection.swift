//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/CalendarSelection.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.

import Foundation

/// Which calendars the widget and the in-app agenda show.
///
/// The widget has no configuration sheet — every setting lives in the app (§11). This
/// value is persisted to the App Group and read by both the widget extension and the
/// app's preview.
///
/// `refs == nil` means **not configured → show every calendar**, and a newly added
/// calendar appears automatically. Once the user hand-picks, `refs` is an explicit list
/// (possibly empty → show nothing). Selecting every known calendar collapses back to
/// `nil`, so "all" stays sticky.
public struct CalendarSelection: Codable, Sendable, Equatable {
    /// `nil` == all calendars (see type doc). Encodes as an absent key.
    public var refs: [CalendarRef]?

    public static let all = CalendarSelection(refs: nil)

    public init(refs: [CalendarRef]?) {
        self.refs = refs
    }

    /// True when nothing is hand-picked — every calendar shows, new ones included.
    public var isAll: Bool { refs == nil }

    /// Is this calendar shown under the current selection? Matches by identifier, then by
    /// title + source (identifier drift, §6.5).
    public func includes(_ info: CalendarInfo) -> Bool {
        guard let refs else { return true }
        return refs.contains { $0.id == info.id || ($0.title == info.title && $0.sourceTitle == info.sourceTitle) }
    }

    /// Resolve to concrete EventKit identifiers. `nil` == all calendars. An explicit but
    /// empty selection stays `[]` (show nothing) — callers must not treat it as "all".
    public func resolvedIDs(in available: [CalendarInfo]) -> [String]? {
        guard let refs else { return nil }
        return refs.compactMap { $0.resolve(in: available)?.id }
    }

    /// Apply one checkbox toggle against the full calendar list, collapsing to `.all` when
    /// every calendar ends up selected.
    public func setting(_ info: CalendarInfo, included: Bool, among available: [CalendarInfo]) -> CalendarSelection {
        var chosen = Set(available.filter { includes($0) }.map(\.id))
        if included { chosen.insert(info.id) } else { chosen.remove(info.id) }
        guard chosen.count < available.count else { return .all }
        return CalendarSelection(refs: available.filter { chosen.contains($0.id) }.map(CalendarRef.init))
    }
}

/// Reads and writes `CalendarSelection` in the App Group, so the widget extension and the
/// app agree (like `PageState`). One source of truth, edited only in the app.
public enum CalendarSelectionStore {
    /// Veyrn's App Group, not Calvane's — one source of truth, shared with the rest
    /// of the app rather than restating the suite name here.
    public static var appGroup: String { VikunjaConfig.appGroupSuite }
    /// Namespaced on the move into Veyrn: this suite now holds task keys too.
    static let key = "calendar.selection.v1"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// The stored selection, or `.all` when nothing has been saved (or it fails to decode).
    public static func load() -> CalendarSelection {
        guard let data = defaults?.data(forKey: key),
              let decoded = try? JSONDecoder().decode(CalendarSelection.self, from: data)
        else { return .all }
        return decoded
    }

    public static func save(_ selection: CalendarSelection) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults?.set(data, forKey: key)
    }
}
