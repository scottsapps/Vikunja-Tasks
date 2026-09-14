//  Vendored from Calvane Widget — AgendaKit/Tests/AgendaKitTests/FillTests.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.

import Testing
import Foundation
import CoreGraphics
@testable import Veyrn

private func cal() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    c.locale = Locale(identifier: "en_US_POSIX")
    return c
}

private func at(_ c: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

/// Clean round numbers so the budget arithmetic in each test is obvious.
/// titleCharsPerLine is huge, so a normal title is always one line (eventRow); the
/// two-line case is exercised explicitly with a long title.
private let rc = RowCost(
    dayHeader: 20, allDayChip: 20, eventRow: 40, eventRow3: 60, divider: 10,
    titleCharsPerLine: 1000
)

/// N one-line timed events on the same day, 1 hour each starting on the hour.
private func timedDay(_ c: Calendar, _ y: Int, _ mo: Int, _ d: Int, count: Int, firstHour: Int = 9) -> [AgendaEvent] {
    (0..<count).map { i in
        AgendaEvent.fixture(
            id: "\(y)-\(mo)-\(d)-\(i)",
            title: "Event \(i)",
            start: at(c, y, mo, d, firstHour + i),
            end: at(c, y, mo, d, firstHour + i + 1)
        )
    }
}

@Suite("fill — §6.3")
struct FillTests {

    @Test("empty input")
    func empty() {
        let page = fill(from: nil, budget: 500, events: [], calendar: cal(), cost: rc)
        #expect(page == Page.empty)
        #expect(page.nextCursor == nil)
    }

    @Test("single event fits, forward chevron disabled")
    func single() {
        let c = cal()
        let page = fill(from: nil, budget: 500, events: timedDay(c, 2026, 9, 5, count: 1), calendar: c, cost: rc)
        #expect(page.sections.count == 1)
        #expect(page.sections[0].items.count == 1)
        #expect(page.nextCursor == nil)
        #expect(!page.isContinuation)
    }

    @Test("exact-fit boundary: everything fits at cost, spills one point under")
    func exactFit() {
        let c = cal()
        let events = timedDay(c, 2026, 9, 5, count: 3)
        // total = header 20 + 3 * 40 = 140
        let exact = fill(from: nil, budget: 140, events: events, calendar: c, cost: rc)
        #expect(exact.sections.map { $0.items.count } == [3])
        #expect(exact.nextCursor == nil)

        let under = fill(from: nil, budget: 139, events: events, calendar: c, cost: rc)
        #expect(under.sections.map { $0.items.count } == [2])
        #expect(under.nextCursor == Cursor(day: at(c, 2026, 9, 5), itemIndex: 2))
        #expect(!under.isContinuation)
    }

    @Test("day split mid-section repeats the header on page 1")
    func daySplitRepeatsHeader() {
        let c = cal()
        let events = timedDay(c, 2026, 9, 5, count: 5)
        let day = at(c, 2026, 9, 5)

        // budget = 20 + 2*40 = 100 -> 2 items on page 0
        let page0 = fill(from: nil, budget: 100, events: events, calendar: c, cost: rc)
        #expect(page0.sections.map { $0.items.count } == [2])
        #expect(page0.isContinuation == false)
        let cursor = try! #require(page0.nextCursor)
        #expect(cursor == Cursor(day: day, itemIndex: 2))

        let page1 = fill(from: cursor, budget: 100, events: events, calendar: c, cost: rc)
        #expect(page1.isContinuation)                       // header repeated
        #expect(page1.sections.count == 1)
        #expect(page1.sections[0].day == day)
        #expect(page1.sections[0].items.map(\.event.id) == ["2026-9-5-2", "2026-9-5-3"])
        #expect(page1.nextCursor == Cursor(day: day, itemIndex: 4))
    }

    @Test("a section whose header fits but whose first row does not is dropped whole")
    func dropHeaderOnlySection() {
        let c = cal()
        // Day A: 2 events (fills most of the budget). Day B: 1 event.
        let events = timedDay(c, 2026, 9, 5, count: 2) + timedDay(c, 2026, 9, 6, count: 1)
        // budget = 20 + 2*40 = 100 exactly consumes day A. Day B needs 10+20+40 more.
        let page = fill(from: nil, budget: 105, events: events, calendar: c, cost: rc)
        #expect(page.sections.map(\.day) == [at(c, 2026, 9, 5)])   // day B not started
        #expect(page.nextCursor == Cursor(day: at(c, 2026, 9, 6), itemIndex: 0))
    }

    @Test("all-day-only day")
    func allDayOnly() {
        let c = cal()
        let events = [
            AgendaEvent.fixture(id: "b1", title: "Carter's Birthday", start: at(c, 2026, 9, 5), end: at(c, 2026, 9, 6), isAllDay: true),
            AgendaEvent.fixture(id: "b2", title: "Payday", start: at(c, 2026, 9, 5), end: at(c, 2026, 9, 6), isAllDay: true),
        ]
        // total = 20 + 2*20 = 60
        #expect(fill(from: nil, budget: 60, events: events, calendar: c, cost: rc).sections[0].items.count == 2)

        let tight = fill(from: nil, budget: 40, events: events, calendar: c, cost: rc)
        #expect(tight.sections[0].items.count == 1)
        #expect(tight.nextCursor == Cursor(day: at(c, 2026, 9, 5), itemIndex: 1))
    }

    @Test("multi-day event spanning three days is counted once per day")
    func multiDayThreeDays() {
        let c = cal()
        let trip = AgendaEvent.fixture(id: "trip", title: "Trip", start: at(c, 2026, 9, 5), end: at(c, 2026, 9, 8), isAllDay: true)

        // Cost: (20+20) + (10+20+20) + (10+20+20) = 140. Exact fit -> all three.
        let full = fill(from: nil, budget: 140, events: [trip], calendar: c, cost: rc)
        #expect(full.sections.map(\.day) == [at(c, 2026, 9, 5), at(c, 2026, 9, 6), at(c, 2026, 9, 7)])
        #expect(full.sections.allSatisfy { $0.items.count == 1 })
        #expect(full.nextCursor == nil)

        // 139 drops the third day's header-only section.
        let clipped = fill(from: nil, budget: 139, events: [trip], calendar: c, cost: rc)
        #expect(clipped.sections.map(\.day) == [at(c, 2026, 9, 5), at(c, 2026, 9, 6)])
        #expect(clipped.nextCursor == Cursor(day: at(c, 2026, 9, 7), itemIndex: 0))
    }

    @Test("two-line title costs eventRow3")
    func twoLineTitle() {
        let c = cal()
        let narrow = RowCost(dayHeader: 20, allDayChip: 20, eventRow: 40, eventRow3: 60, divider: 10, titleCharsPerLine: 10)
        let short = AgendaEvent.fixture(id: "s", title: "Lunch", start: at(c, 2026, 9, 5, 12), end: at(c, 2026, 9, 5, 13))
        let long = AgendaEvent.fixture(id: "l", title: "Atlanta Braves at Philadelphia Phillies", start: at(c, 2026, 9, 5, 18), end: at(c, 2026, 9, 5, 20))

        // header 20 + short 40 + long 60 = 120
        let page = fill(from: nil, budget: 120, events: [short, long], calendar: c, cost: narrow)
        #expect(page.sections[0].items.count == 2)
        #expect(page.nextCursor == nil)

        #expect(fill(from: nil, budget: 119, events: [short, long], calendar: c, cost: narrow).sections[0].items.count == 1)
    }

    @Test("DST transition day pages without surprises")
    func dstDay() {
        let c = cal() // 2026-03-08 spring forward
        let events = timedDay(c, 2026, 3, 8, count: 2, firstHour: 6) + timedDay(c, 2026, 3, 9, count: 1)
        let page = fill(from: nil, budget: 500, events: events, calendar: c, cost: rc)
        #expect(page.sections.map(\.day) == [at(c, 2026, 3, 8), at(c, 2026, 3, 9)])
        #expect(page.sections.map { $0.items.count } == [2, 1])
        #expect(page.nextCursor == nil)
    }

    @Test("stale cursor resumes at the first later day")
    func staleCursor() {
        let c = cal()
        let events = timedDay(c, 2026, 9, 6, count: 1) + timedDay(c, 2026, 9, 7, count: 1)
        // cursor points at Sept 5, which no longer has events
        let page = fill(from: Cursor(day: at(c, 2026, 9, 5), itemIndex: 3), budget: 500, events: events, calendar: c, cost: rc)
        #expect(page.sections.map(\.day) == [at(c, 2026, 9, 6), at(c, 2026, 9, 7)])
        #expect(!page.isContinuation)
    }

    @Test("cursor past the end yields an empty page")
    func cursorPastEnd() {
        let c = cal()
        let events = timedDay(c, 2026, 9, 6, count: 1)
        let page = fill(from: Cursor(day: at(c, 2026, 9, 20), itemIndex: 0), budget: 500, events: events, calendar: c, cost: rc)
        #expect(page == Page.empty)
    }

    @Test("tiny budget still yields a non-empty page 1 (forced first row)")
    func neverBlankPageOne() {
        let c = cal()
        let events = timedDay(c, 2026, 9, 5, count: 3)
        // budget can't fit header + a row; page 0 already forced one row.
        let page0 = fill(from: nil, budget: 10, events: events, calendar: c, cost: rc)
        #expect(page0.sections.count == 1)
        #expect(page0.sections[0].items.count == 1)
        #expect(page0.nextCursor == Cursor(day: at(c, 2026, 9, 5), itemIndex: 1))
    }
}
