//  Vendored from Calvane Widget — AgendaKit/Tests/AgendaKitTests/DayGroupingTests.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.

import Testing
import Foundation
@testable import Veyrn

/// A Gregorian calendar pinned to a fixed time zone, so grouping tests don't depend on
/// where the machine running them happens to be.
private func calendar(_ tzID: String = "America/New_York") -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: tzID)!
    cal.locale = Locale(identifier: "en_US_POSIX")
    return cal
}

private func date(_ cal: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

@Suite("DayGrouping — §6.2")
struct DayGroupingTests {

    @Test("empty input yields no sections")
    func empty() {
        #expect(DayGrouping.sections(for: [], in: calendar()).isEmpty)
    }

    @Test("a single-day timed event lands on exactly one day, unclamped")
    func singleDay() {
        let cal = calendar()
        let e = AgendaEvent.fixture(
            start: date(cal, 2026, 9, 5, 18, 5),
            end: date(cal, 2026, 9, 5, 20, 5)
        )
        let sections = DayGrouping.sections(for: [e], in: cal)
        #expect(sections.count == 1)
        #expect(sections[0].day == date(cal, 2026, 9, 5))
        let item = sections[0].items[0]
        #expect(item.displayStart == e.start)
        #expect(item.displayEnd == e.end)
        #expect(!item.continuesBeforeToday)
        #expect(!item.continuesAfterToday)
    }

    @Test("a timed event crossing midnight appears on both days, clamped")
    func crossesMidnight() {
        let cal = calendar()
        let e = AgendaEvent.fixture(
            start: date(cal, 2026, 9, 5, 23, 0),
            end: date(cal, 2026, 9, 6, 1, 0)
        )
        let sections = DayGrouping.sections(for: [e], in: cal)
        #expect(sections.map(\.day) == [date(cal, 2026, 9, 5), date(cal, 2026, 9, 6)])

        let first = sections[0].items[0]
        #expect(first.displayStart == e.start)
        #expect(first.displayEnd == date(cal, 2026, 9, 6))
        #expect(first.continuesAfterToday)
        #expect(!first.continuesBeforeToday)

        let second = sections[1].items[0]
        #expect(second.displayStart == date(cal, 2026, 9, 6))
        #expect(second.displayEnd == e.end)
        #expect(second.continuesBeforeToday)
        #expect(!second.continuesAfterToday)
    }

    @Test("a 3-day all-day event appears on exactly its 3 days")
    func multiDaySpansThree() {
        let cal = calendar()
        // EventKit-style all-day span: [Sep 5 00:00, Sep 8 00:00) covers the 5th, 6th, 7th.
        let e = AgendaEvent.fixture(
            title: "Trip",
            start: date(cal, 2026, 9, 5),
            end: date(cal, 2026, 9, 8),
            isAllDay: true
        )
        let sections = DayGrouping.sections(for: [e], in: cal)
        #expect(sections.map(\.day) == [
            date(cal, 2026, 9, 5), date(cal, 2026, 9, 6), date(cal, 2026, 9, 7)
        ])
        #expect(sections[1].items[0].continuesBeforeToday)
        #expect(sections[1].items[0].continuesAfterToday)
        #expect(sections[0].items[0].displayStart == date(cal, 2026, 9, 5))
        #expect(sections[2].items[0].displayEnd == date(cal, 2026, 9, 8))
    }

    @Test("an event ending exactly at midnight does not leak into the next day")
    func endsAtMidnight() {
        let cal = calendar()
        let e = AgendaEvent.fixture(
            start: date(cal, 2026, 9, 5, 18, 0),
            end: date(cal, 2026, 9, 6, 0, 0)
        )
        let sections = DayGrouping.sections(for: [e], in: cal)
        #expect(sections.map(\.day) == [date(cal, 2026, 9, 5)])
        #expect(!sections[0].items[0].continuesAfterToday)
    }

    @Test("all-day sorts above timed; then by start, duration desc, title")
    func ordering() {
        let cal = calendar()
        let timedLate = AgendaEvent.fixture(id: "c", title: "Zebra", start: date(cal, 2026, 9, 5, 18), end: date(cal, 2026, 9, 5, 19))
        let timedEarlyLong = AgendaEvent.fixture(id: "b", title: "Apple", start: date(cal, 2026, 9, 5, 9), end: date(cal, 2026, 9, 5, 17))
        let timedEarlyShort = AgendaEvent.fixture(id: "d", title: "Beta", start: date(cal, 2026, 9, 5, 9), end: date(cal, 2026, 9, 5, 10))
        let allDay = AgendaEvent.fixture(id: "a", title: "Holiday", start: date(cal, 2026, 9, 5), end: date(cal, 2026, 9, 6), isAllDay: true)

        let items = DayGrouping.sections(for: [timedLate, timedEarlyShort, allDay, timedEarlyLong], in: cal)[0].items
        #expect(items.map(\.event.id) == ["a", "b", "d", "c"])
    }

    @Test("ordering is a total order — same key falls back to id")
    func orderingDeterministicTiebreak() {
        let cal = calendar()
        let start = date(cal, 2026, 9, 5, 9)
        let end = date(cal, 2026, 9, 5, 10)
        let e1 = AgendaEvent.fixture(id: "zzz", title: "Same", start: start, end: end)
        let e2 = AgendaEvent.fixture(id: "aaa", title: "Same", start: start, end: end)
        let forward = DayGrouping.sections(for: [e1, e2], in: cal)[0].items.map(\.event.id)
        let reversed = DayGrouping.sections(for: [e2, e1], in: cal)[0].items.map(\.event.id)
        #expect(forward == ["aaa", "zzz"])
        #expect(forward == reversed)
    }

    @Test("zero-duration event lands on the day of its instant")
    func zeroDuration() {
        let cal = calendar()
        let instant = date(cal, 2026, 9, 5, 9, 30)
        let e = AgendaEvent.fixture(start: instant, end: instant)
        let sections = DayGrouping.sections(for: [e], in: cal)
        #expect(sections.map(\.day) == [date(cal, 2026, 9, 5)])
        #expect(sections[0].items[0].displayStart == instant)
        #expect(sections[0].items[0].displayEnd == instant)
    }

    @Test("DST spring-forward day: a timed event stays on that one day")
    func dstSpringForwardTimed() {
        let cal = calendar() // America/New_York; 2026-03-08 skips 02:00→03:00
        let e = AgendaEvent.fixture(
            start: date(cal, 2026, 3, 8, 1, 0),
            end: date(cal, 2026, 3, 8, 5, 0)
        )
        let sections = DayGrouping.sections(for: [e], in: cal)
        #expect(sections.map(\.day) == [date(cal, 2026, 3, 8)])
        #expect(!sections[0].items[0].continuesAfterToday)
        #expect(!sections[0].items[0].continuesBeforeToday)
    }

    @Test("DST fall-back day: a multi-day event still covers each calendar day once")
    func dstFallBackMultiDay() {
        let cal = calendar() // 2026-11-01 has a 25-hour day
        let e = AgendaEvent.fixture(
            title: "Long weekend",
            start: date(cal, 2026, 10, 31),
            end: date(cal, 2026, 11, 3),
            isAllDay: true
        )
        let sections = DayGrouping.sections(for: [e], in: cal)
        #expect(sections.map(\.day) == [
            date(cal, 2026, 10, 31), date(cal, 2026, 11, 1), date(cal, 2026, 11, 2)
        ])
    }

    @Test("window filter drops days outside the fetch horizon")
    func windowFilter() {
        let cal = calendar()
        let inside = AgendaEvent.fixture(id: "in", start: date(cal, 2026, 9, 6, 12), end: date(cal, 2026, 9, 6, 13))
        let outside = AgendaEvent.fixture(id: "out", start: date(cal, 2026, 9, 20, 12), end: date(cal, 2026, 9, 20, 13))
        let window = DateInterval(start: date(cal, 2026, 9, 5), end: date(cal, 2026, 9, 12))
        let sections = DayGrouping.sections(for: [inside, outside], in: cal, within: window)
        #expect(sections.map(\.day) == [date(cal, 2026, 9, 6)])
    }

    @Test("grouping uses the supplied time zone, not the machine's")
    func timeZoneMatters() {
        // 2026-09-05 23:30 in New York is already 2026-09-06 in UTC.
        let ny = calendar("America/New_York")
        let utc = calendar("UTC")
        let instant = ny.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 23, minute: 30))!
        let e = AgendaEvent.fixture(start: instant, end: instant.addingTimeInterval(1800))

        #expect(DayGrouping.sections(for: [e], in: ny)[0].day == date(ny, 2026, 9, 5))
        #expect(DayGrouping.sections(for: [e], in: utc)[0].day == date(utc, 2026, 9, 6))
    }
}
