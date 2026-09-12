//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/FakeEventSource.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.

#if DEBUG
import Foundation

/// An in-memory `EventSource` for tests and SwiftUI previews (§6.4). Compiled only in
/// `DEBUG` so it can't leak into a release build.
public struct FakeEventSource: EventSource {
    public var allEvents: [AgendaEvent]
    public var allCalendars: [CalendarInfo]
    /// When set, every call throws this instead of returning data — for exercising the
    /// widget's "no access" / failure states (§10).
    public var failure: EventSourceError?

    public init(
        events: [AgendaEvent] = [],
        calendars: [CalendarInfo] = [],
        failure: EventSourceError? = nil
    ) {
        self.allEvents = events
        self.allCalendars = calendars
        self.failure = failure
    }

    public func events(from: Date, to: Date, calendarIDs: [String]?) async throws -> [AgendaEvent] {
        if let failure { throw failure }
        let window = DateInterval(start: from, end: max(from, to))
        return allEvents.filter { event in
            event.intersects(window) && (calendarIDs.map { $0.contains(event.calendarID) } ?? true)
        }
    }

    public func calendars() async throws -> [CalendarInfo] {
        if let failure { throw failure }
        return allCalendars
    }
}

public extension AgendaEvent {
    /// Fixture builder. `DEBUG`-only; keeps test call sites short.
    static func fixture(
        id: String = UUID().uuidString,
        title: String = "Event",
        location: String? = nil,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        color: CodableColor = CodableColor(red: 0.2, green: 0.5, blue: 0.9),
        calendarID: String = "cal-1"
    ) -> AgendaEvent {
        AgendaEvent(
            id: id,
            title: title,
            location: location,
            start: start,
            end: end,
            isAllDay: isAllDay,
            calendarColor: color,
            calendarID: calendarID
        )
    }
}
#endif
