//  Vendored from Calvane Widget — AgendaKit/Tests/AgendaKitTests/CalendarSelectionTests.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.

import Testing
import Foundation
@testable import Veyrn

private func cal(_ id: String, _ title: String = "T", _ source: String = "iCloud") -> CalendarInfo {
    CalendarInfo(id: id, title: title, sourceTitle: source, color: .init(red: 0, green: 0, blue: 0))
}

@Suite("CalendarSelection")
struct CalendarSelectionTests {

    @Test("nil selection means every calendar")
    func allIncludesEverything() {
        let s = CalendarSelection.all
        #expect(s.isAll)
        #expect(s.includes(cal("a")))
        #expect(s.resolvedIDs(in: [cal("a"), cal("b")]) == nil)
    }

    @Test("an explicit empty selection shows nothing, not everything")
    func emptyShowsNothing() {
        let s = CalendarSelection(refs: [])
        #expect(!s.isAll)
        #expect(!s.includes(cal("a")))
        #expect(s.resolvedIDs(in: [cal("a")]) == [])
    }

    @Test("explicit selection resolves by id, then title + source")
    func resolveWithDrift() {
        let available = [cal("new-id", "Work", "iCloud"), cal("home", "Home", "iCloud")]
        let s = CalendarSelection(refs: [CalendarRef(id: "old-id", title: "Work", sourceTitle: "iCloud")])
        #expect(s.resolvedIDs(in: available) == ["new-id"])
        #expect(s.includes(cal("whatever", "Work", "iCloud")))
    }

    @Test("unchecking one calendar drops it from an all-selection")
    func toggleOffFromAll() {
        let available = [cal("a"), cal("b"), cal("c")]
        let s = CalendarSelection.all.setting(cal("b"), included: false, among: available)
        #expect(!s.isAll)
        #expect(s.resolvedIDs(in: available)?.sorted() == ["a", "c"])
    }

    @Test("re-checking the last calendar collapses back to all")
    func toggleOnCollapsesToAll() {
        let available = [cal("a"), cal("b")]
        let partial = CalendarSelection(refs: [CalendarRef(cal("a"))])
        let s = partial.setting(cal("b"), included: true, among: available)
        #expect(s.isAll)
    }
}

@Suite("WidgetOptions")
struct WidgetOptionsTests {

    @Test("defaults")
    func defaults() {
        let o = WidgetOptions.default
        #expect(o.daysAhead == 14)
        #expect(o.showAllDay)
        #expect(o.showDeclined)
    }

    @Test("effectiveDaysAhead clamps to a pageable range")
    func clampsDaysAhead() {
        #expect(WidgetOptions(daysAhead: 0).effectiveDaysAhead == 2)
        #expect(WidgetOptions(daysAhead: 9_999).effectiveDaysAhead == WidgetOptions.daysAheadRange.upperBound)
        #expect(WidgetOptions(daysAhead: 21).effectiveDaysAhead == 21)
    }

    @Test("JSON round-trip")
    func roundTrip() throws {
        let o = WidgetOptions(daysAhead: 7, showAllDay: false, showDeclined: true)
        let back = try JSONDecoder().decode(WidgetOptions.self, from: JSONEncoder().encode(o))
        #expect(back == o)
    }
}

/// These touch the shared App Group `UserDefaults`, so they run one at a time from a clean
/// slate.
@Suite("App Group stores", .serialized)
struct AppGroupStoreTests {

    init() { reset() }

    private func reset() {
        let defaults = UserDefaults(suiteName: CalendarSelectionStore.appGroup)
        defaults?.removeObject(forKey: CalendarSelectionStore.key)
        defaults?.removeObject(forKey: WidgetOptionsStore.key)
    }

    @Test("calendar selection: save then load round-trips")
    func selectionRoundTrip() {
        let available = [cal("a"), cal("b"), cal("c")]
        let picked = CalendarSelection.all.setting(cal("a"), included: false, among: available)
        CalendarSelectionStore.save(picked)
        #expect(CalendarSelectionStore.load() == picked)

        CalendarSelectionStore.save(.all)
        #expect(CalendarSelectionStore.load().isAll)
    }

    @Test("calendar selection: missing key loads as .all")
    func selectionMissingKeyIsAll() {
        #expect(CalendarSelectionStore.load().isAll)
    }

    @Test("widget options: save then load round-trips")
    func optionsRoundTrip() {
        let picked = WidgetOptions(daysAhead: 30, showAllDay: false, showDeclined: false)
        WidgetOptionsStore.save(picked)
        #expect(WidgetOptionsStore.load() == picked)
    }

    @Test("widget options: missing key loads as .default")
    func optionsMissingKeyIsDefault() {
        #expect(WidgetOptionsStore.load() == .default)
    }
}
