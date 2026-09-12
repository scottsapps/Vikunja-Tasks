//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/AgendaEvent.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.

import Foundation

/// A calendar event, flattened for the UI. `EKEvent` never crosses into `VeyrnCalendar`'s
/// public API or the views (§3, §6.1): this keeps the type `Sendable`, keeps previews and
/// tests working against the same code, and kept the (now-dropped) snapshot path honest.
public struct AgendaEvent: Identifiable, Codable, Hashable, Sendable {
    /// `eventIdentifier` combined with the occurrence's start — recurring events reuse a
    /// single identifier across occurrences, so the identifier alone is not unique.
    public let id: String
    public let title: String
    public let location: String?
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let calendarColor: CodableColor
    public let calendarID: String
    /// The event has a video-conference link (Zoom / Meet / Teams / Webex / …). The row
    /// shows a camera glyph instead of a bare meeting URL.
    public let isVideoConference: Bool
    /// The current user has declined this invite. Shown dimmed with a gear glyph, not
    /// hidden, unless the config opts out (§11).
    public let isDeclined: Bool
    /// The current user answered "maybe" to this invite. Shown dimmed with a hollow dot —
    /// a lighter treatment than declined, always visible. `isDeclined` takes precedence
    /// if both are somehow set.
    public let isTentative: Bool

    public init(
        id: String,
        title: String,
        location: String?,
        start: Date,
        end: Date,
        isAllDay: Bool,
        calendarColor: CodableColor,
        calendarID: String,
        isVideoConference: Bool = false,
        isDeclined: Bool = false,
        isTentative: Bool = false
    ) {
        self.id = id
        self.title = title
        self.location = location
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarColor = calendarColor
        self.calendarID = calendarID
        self.isVideoConference = isVideoConference
        self.isDeclined = isDeclined
        self.isTentative = isTentative
    }
}

public extension AgendaEvent {
    /// `end - start`, never negative.
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// Whether the event covers any part of `interval` (touching only at the very end
    /// does not count, matching how a `[start, end)` half-open span reads on screen).
    func intersects(_ interval: DateInterval) -> Bool {
        start < interval.end && end > interval.start
    }
}
