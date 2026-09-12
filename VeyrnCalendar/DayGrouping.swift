//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/DayGrouping.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.

import Foundation

/// Groups a flat event list into ordered day sections (§6.2).
///
/// Pure and deterministic: it takes the calendar (hence the time zone) explicitly and
/// reads nothing from `Date()` or user defaults, so `fill` (§6.3) and the tests can drive
/// it with fixed inputs.
///
/// Rules implemented here:
/// - An event appears in **every day its `[start, end)` span intersects**, not just the
///   day of its start. A single-day timed event therefore lands on exactly one day; one
///   that crosses midnight lands on both, clamped.
/// - Each `DayItem`'s range is clamped to that day's bounds, with
///   `continuesBefore/AfterToday` set when the real event extends past them.
/// - Zero-duration events land on the day containing their instant.
/// - Days with no items are omitted. Within a day, items use `DayItem.order`.
///
/// Declined-event filtering (§6.2, §11) happens **before** this call — the input is
/// assumed to already be the set the user should see.
public enum DayGrouping {
    /// Guards against a malformed event (e.g. `end` far in the future) expanding into an
    /// unbounded number of days and hanging the timeline. Two years of days is far more
    /// than any widget shows.
    static let maxSpanDays = 732

    public static func sections(
        for events: [AgendaEvent],
        in calendar: Calendar,
        within window: DateInterval? = nil
    ) -> [DaySection] {
        var itemsByDay: [Date: [DayItem]] = [:]

        for event in events {
            for item in dayItems(for: event, in: calendar) {
                let key = calendar.startOfDay(for: item.displayStart)
                if let window {
                    guard let dayInterval = calendar.dateInterval(of: .day, for: key),
                          dayInterval.intersects(window) else { continue }
                }
                itemsByDay[key, default: []].append(item)
            }
        }

        return itemsByDay
            .map { day, items in DaySection(day: day, items: items.sorted(by: DayItem.order)) }
            .sorted { $0.day < $1.day }
    }

    /// Explodes one event into its per-day `DayItem`s.
    static func dayItems(for event: AgendaEvent, in calendar: Calendar) -> [DayItem] {
        let zeroDuration = event.end <= event.start
        var result: [DayItem] = []
        var dayStart = calendar.startOfDay(for: event.start)
        var produced = 0

        while produced < maxSpanDays {
            guard let dayInterval = calendar.dateInterval(of: .day, for: dayStart) else { break }

            let isMember: Bool
            if zeroDuration {
                isMember = dayInterval.contains(event.start) || dayInterval.start == event.start
            } else {
                isMember = event.start < dayInterval.end && event.end > dayInterval.start
            }

            if isMember {
                let clampedStart = max(event.start, dayInterval.start)
                let clampedEnd = zeroDuration ? event.start : min(event.end, dayInterval.end)
                result.append(
                    DayItem(
                        event: event,
                        displayStart: clampedStart,
                        displayEnd: clampedEnd,
                        continuesBeforeToday: event.start < dayInterval.start,
                        continuesAfterToday: !zeroDuration && event.end > dayInterval.end
                    )
                )
            }

            produced += 1

            // Stop once we're past the event. For zero-duration events the single
            // membership check above is enough.
            if zeroDuration || dayInterval.end >= event.end { break }
            guard let next = calendar.date(byAdding: .day, value: 1, to: dayInterval.start) else { break }
            dayStart = next
        }

        return result
    }
}
