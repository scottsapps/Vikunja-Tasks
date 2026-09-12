//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/CalendarInfo.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.

import Foundation

/// A calendar the user could show in the widget. Populated from `EKCalendar` and surfaced
/// in the configuration intent's picker (§11).
///
/// `EKCalendar.calendarIdentifier` is **not stable**: removing and re-adding an account
/// mints a new identifier, which would silently blank a configured widget. So a saved
/// selection persists `{id, title, sourceTitle}` and is resolved by identifier first,
/// then by `title` + `sourceTitle` as a fallback (§6.5).
public struct CalendarInfo: Identifiable, Codable, Hashable, Sendable {
    /// `EKCalendar.calendarIdentifier`.
    public let id: String
    public let title: String
    /// `EKCalendar.source.title` — e.g. "iCloud", "Other", "Subscribed Calendars".
    public let sourceTitle: String
    public let color: CodableColor

    public init(id: String, title: String, sourceTitle: String, color: CodableColor) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
        self.color = color
    }
}

public extension CalendarInfo {
    /// The picker order (§11): by source, then title, both case-insensitively, with `id`
    /// as a final tiebreaker so the order is deterministic.
    static func pickerOrder(_ a: CalendarInfo, _ b: CalendarInfo) -> Bool {
        let source = a.sourceTitle.localizedCaseInsensitiveCompare(b.sourceTitle)
        if source != .orderedSame { return source == .orderedAscending }
        let title = a.title.localizedCaseInsensitiveCompare(b.title)
        if title != .orderedSame { return title == .orderedAscending }
        return a.id < b.id
    }
}

/// A persisted reference to a chosen calendar, resilient to identifier drift (§6.5).
public struct CalendarRef: Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let sourceTitle: String

    public init(id: String, title: String, sourceTitle: String) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
    }

    public init(_ info: CalendarInfo) {
        self.init(id: info.id, title: info.title, sourceTitle: info.sourceTitle)
    }

    /// Resolve against the current calendar list: exact identifier match wins; otherwise
    /// fall back to an exact `title` + `sourceTitle` match. Returns `nil` if neither hits.
    public func resolve(in calendars: [CalendarInfo]) -> CalendarInfo? {
        if let byID = calendars.first(where: { $0.id == id }) { return byID }
        return calendars.first { $0.title == title && $0.sourceTitle == sourceTitle }
    }
}
