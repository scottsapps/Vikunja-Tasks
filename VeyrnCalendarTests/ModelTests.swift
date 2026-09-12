//  Vendored from Calvane Widget — AgendaKit/Tests/AgendaKitTests/ModelTests.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.

import Testing
import Foundation
import CoreGraphics
@testable import Veyrn

@Suite("Model types")
struct ModelTests {

    @Test("CodableColor survives a JSON round-trip")
    func codableColorRoundTrip() throws {
        let color = CodableColor(red: 0.1, green: 0.42, blue: 0.998, alpha: 0.75)
        let data = try JSONEncoder().encode(color)
        let back = try JSONDecoder().decode(CodableColor.self, from: data)
        #expect(back == color)
    }

    @Test("CodableColor <-> CGColor preserves sRGB components")
    func codableColorCGColor() {
        let color = CodableColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let back = CodableColor(cgColor: color.cgColor)
        #expect(abs(back.red - 0.2) < 0.001)
        #expect(abs(back.green - 0.4) < 0.001)
        #expect(abs(back.blue - 0.6) < 0.001)
        #expect(abs(back.alpha - 1) < 0.001)
    }

    @Test("CodableColor from a grayscale CGColor expands to RGB")
    func codableColorGrayscale() {
        let gray = CGColor(gray: 0.3, alpha: 0.9)
        let c = CodableColor(cgColor: gray)
        #expect(abs(c.red - c.green) < 0.001)
        #expect(abs(c.green - c.blue) < 0.001)
        #expect(abs(c.alpha - 0.9) < 0.01)
    }

    @Test("AgendaEvent duration is never negative")
    func durationClamped() {
        let now = Date()
        let e = AgendaEvent.fixture(start: now, end: now.addingTimeInterval(-100))
        #expect(e.duration == 0)
    }

    @Test("CalendarRef resolves by identifier first")
    func calendarRefByID() {
        let cal = CalendarInfo(id: "abc", title: "Work", sourceTitle: "iCloud", color: .init(red: 0, green: 0, blue: 1))
        let ref = CalendarRef(id: "abc", title: "STALE", sourceTitle: "STALE")
        #expect(ref.resolve(in: [cal])?.id == "abc")
    }

    @Test("CalendarRef falls back to title + source when the identifier drifted")
    func calendarRefFallback() {
        let cal = CalendarInfo(id: "new-id", title: "Work", sourceTitle: "iCloud", color: .init(red: 0, green: 0, blue: 1))
        let ref = CalendarRef(id: "old-id", title: "Work", sourceTitle: "iCloud")
        #expect(ref.resolve(in: [cal])?.id == "new-id")
    }

    @Test("CalendarRef returns nil when nothing matches")
    func calendarRefNoMatch() {
        let cal = CalendarInfo(id: "x", title: "Home", sourceTitle: "iCloud", color: .init(red: 0, green: 0, blue: 1))
        let ref = CalendarRef(id: "y", title: "Work", sourceTitle: "Google")
        #expect(ref.resolve(in: [cal]) == nil)
    }

    @Test("picker order is by source, then title, case-insensitively")
    func pickerOrder() {
        let a = CalendarInfo(id: "1", title: "zeta", sourceTitle: "iCloud", color: .init(red: 0, green: 0, blue: 0))
        let b = CalendarInfo(id: "2", title: "Alpha", sourceTitle: "iCloud", color: .init(red: 0, green: 0, blue: 0))
        let c = CalendarInfo(id: "3", title: "Anything", sourceTitle: "Exchange", color: .init(red: 0, green: 0, blue: 0))
        let sorted = [a, b, c].sorted(by: CalendarInfo.pickerOrder)
        #expect(sorted.map(\.id) == ["3", "2", "1"])
    }
}

@Suite("FakeEventSource")
struct FakeEventSourceTests {

    @Test("returns only events intersecting the requested window")
    func windowFilter() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let hit = AgendaEvent.fixture(id: "hit", start: base, end: base.addingTimeInterval(3600))
        let miss = AgendaEvent.fixture(id: "miss", start: base.addingTimeInterval(100_000), end: base.addingTimeInterval(103_600))
        let source = FakeEventSource(events: [hit, miss])
        let got = try await source.events(from: base.addingTimeInterval(-3600), to: base.addingTimeInterval(3600), calendarIDs: nil)
        #expect(got.map(\.id) == ["hit"])
    }

    @Test("filters by calendar id when asked")
    func calendarFilter() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let a = AgendaEvent.fixture(id: "a", start: base, end: base.addingTimeInterval(60), calendarID: "work")
        let b = AgendaEvent.fixture(id: "b", start: base, end: base.addingTimeInterval(60), calendarID: "home")
        let source = FakeEventSource(events: [a, b])
        let got = try await source.events(from: base.addingTimeInterval(-60), to: base.addingTimeInterval(120), calendarIDs: ["work"])
        #expect(got.map(\.id) == ["a"])
    }

    @Test("throws the configured failure")
    func failure() async {
        let source = FakeEventSource(failure: .notAuthorized)
        await #expect(throws: EventSourceError.notAuthorized) {
            _ = try await source.calendars()
        }
    }
}
