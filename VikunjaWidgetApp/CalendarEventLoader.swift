//
//  CalendarEventLoader.swift
//  VikunjaWidgetApp
//
//  Feeds the Scheduled view its events. Owned by `TodayView`; nothing else reads it.
//
//  Three rules:
//
//  1. **Never block the task list.** `store.upcomingTasks()` is synchronous off cached
//     state and renders immediately; events fill in when EventKit answers. A calendar
//     with many accounts can make `events(matching:)` slow, and tasks must not wait
//     on it.
//  2. **Nothing happens while the master switch is off** — no `EKEventStore`, no
//     query, no observer work. See `CalendarPreferences`.
//  3. **The window starts at the start of today.** Past events never appear. Overdue
//     *tasks* still fold into today the way they always have; that is a task rule and
//     this doesn't touch it.
//

import SwiftUI
import Observation
import EventKit
import WidgetKit

@MainActor
@Observable
final class CalendarEventLoader {
    /// Events grouped by start-of-day, ready for `TaskListView.events`.
    private(set) var eventsByDay: [Date: [DayItem]] = [:]

    /// The `.EKEventStoreChanged` token, parked in a nonisolated box because `deinit`
    /// is not main-actor isolated and so cannot read this class's isolated storage.
    /// Block-based observers are retained by `NotificationCenter` until removed, so
    /// dropping the unregister would leak one per loader.
    private final class ObserverBox: @unchecked Sendable {
        var token: NSObjectProtocol?
    }
    private let box = ObserverBox()
    private var isLoading = false

    deinit {
        if let token = box.token { NotificationCenter.default.removeObserver(token) }
    }

    /// Begin watching for calendar changes. Idempotent.
    ///
    /// In-app this is a plain `NotificationCenter` observer rather than Calvane's
    /// always-running login item: the view is on screen only while Veyrn is in the
    /// foreground, so there is nothing to keep alive.
    func startObserving() {
        guard box.token == nil else { return }
        box.token = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.load()
                // This is the job Calvane's login item existed to do. Veyrn is an app
                // you leave open (global-hotkey Quick Add), so an in-app observer covers
                // it without adding a background launch item — which Veyrn could not do
                // invisibly anyway, lacking `LSUIElement`.
                //
                // The residual gap, deliberately accepted: quit Veyrn on the Mac and the
                // widget falls back to its own 30-minute timeline floor until you reopen
                // it. Documented in `skill/references/calendar.md`.
                WidgetCenter.shared.reloadTimelines(ofKind: VeyrnCalendarWidgetKind)
            }
        }
    }

    func load() async {
        guard CalendarPreferences.isEnabled else {
            eventsByDay = [:]
            return
        }
        guard EventKitSource.authorization.canRead else {
            eventsByDay = [:]
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let options = WidgetOptionsStore.load()
        let selection = CalendarSelectionStore.load()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: options.effectiveDaysAhead, to: start)
            ?? start.addingTimeInterval(Double(options.effectiveDaysAhead) * 86_400)

        do {
            let source = EventKitSource(includeAllDay: options.showAllDay,
                                        includeDeclined: options.showDeclined)
            let all = try await source.calendars()
            let events = try await source.events(from: start, to: end,
                                                 calendarIDs: selection.resolvedIDs(in: all))
            // `DayGrouping` already clamps multi-day events to one item per day and
            // applies the total ordering the widget uses — reuse it rather than
            // re-deriving a second, subtly different order for the list.
            let sections = DayGrouping.sections(for: events, in: calendar)
            eventsByDay = Dictionary(uniqueKeysWithValues: sections.map { ($0.day, $0.items) })
        } catch {
            // Calendar data is user content; log the kind of failure, never the content.
            DiagnosticLog.error("calendar events failed: \(VeyrnError.logDescription(for: error))")
            eventsByDay = [:]
        }
    }
}
