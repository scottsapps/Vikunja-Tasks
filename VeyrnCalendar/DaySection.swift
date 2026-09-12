//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/DaySection.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.

import Foundation

/// One event as it appears **within a single day**. A multi-day event produces one
/// `DayItem` per day it covers, each with its range clamped to that day (§6.2).
public struct DayItem: Identifiable, Hashable, Sendable {
    public let event: AgendaEvent
    /// `event.start` clamped up to the start of this day.
    public let displayStart: Date
    /// `event.end` clamped down to the end of this day (next midnight).
    public let displayEnd: Date
    /// The event began on an earlier day — render a leading continuation hint.
    public let continuesBeforeToday: Bool
    /// The event runs past this day — render a trailing continuation hint.
    public let continuesAfterToday: Bool

    public var id: String { event.id }
    public var isAllDay: Bool { event.isAllDay }
    /// True when the clamped range is the whole day but the event is not itself all-day
    /// (a timed event passing straight through this day).
    public var spansWholeDay: Bool { continuesBeforeToday && continuesAfterToday && !isAllDay }

    public init(
        event: AgendaEvent,
        displayStart: Date,
        displayEnd: Date,
        continuesBeforeToday: Bool,
        continuesAfterToday: Bool
    ) {
        self.event = event
        self.displayStart = displayStart
        self.displayEnd = displayEnd
        self.continuesBeforeToday = continuesBeforeToday
        self.continuesAfterToday = continuesAfterToday
    }
}

/// A day and its ordered items. Days with no items are never produced (§5.6).
public struct DaySection: Identifiable, Hashable, Sendable {
    /// Start of the day, in the calendar used for grouping.
    public let day: Date
    /// Ordered per §6.2: all-day first, then by start, then by duration descending, then
    /// by title, then by id. The order is total and deterministic — the paging cursor
    /// (§6.3, §7) indexes into it.
    public let items: [DayItem]

    public var id: Date { day }

    public init(day: Date, items: [DayItem]) {
        self.day = day
        self.items = items
    }
}

public extension DayItem {
    /// The total ordering within a day (§6.2).
    static func order(_ a: DayItem, _ b: DayItem) -> Bool {
        if a.isAllDay != b.isAllDay { return a.isAllDay }
        if a.displayStart != b.displayStart { return a.displayStart < b.displayStart }
        if a.event.duration != b.event.duration { return a.event.duration > b.event.duration }
        let title = a.event.title.localizedCaseInsensitiveCompare(b.event.title)
        if title != .orderedSame { return title == .orderedAscending }
        return a.event.id < b.event.id
    }
}
