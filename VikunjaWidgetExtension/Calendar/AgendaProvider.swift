//  Vendored from Calvane Widget — Widget/Provider/AgendaProvider.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.
//
//  AgendaProvider.swift
//  Widget
//
//  TimelineProvider (§11) — the widget has no configuration intent. Fetches once via
//  EventKitSource, groups (§6.2), then emits one entry per refresh boundary — every event
//  start/end in the next ~8 hours, the next local midnight, and the page-expiry moment
//  (§8). Content for each entry is computed as of that entry's date, so TODAY/TOMORROW,
//  the visible day set, and the paging reset are all correct when the entry becomes
//  current without a fresh generation.
//

import WidgetKit
import Foundation

struct AgendaProvider: TimelineProvider {
    typealias Entry = AgendaEntry

    func placeholder(in context: Context) -> AgendaEntry { .sample() }

    func getSnapshot(in context: Context, completion: @escaping (AgendaEntry) -> Void) {
        // WidgetKit invokes the completion exactly once, on its own queue; bridging our
        // async work into it is safe. (`TimelineProvider` has no async form.) `Context`
        // isn't Sendable, so pull the two fields we need out before the Task.
        let sink = CompletionSink(completion)
        let family = context.family
        let isPreview = context.isPreview
        Task { sink(await makeSnapshot(family: family, isPreview: isPreview)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AgendaEntry>) -> Void) {
        let sink = CompletionSink(completion)
        let family = context.family
        Task { sink(await makeTimeline(family: family)) }
    }

    /// Carries a WidgetKit completion handler across the `Task` boundary. Safe because
    /// WidgetKit calls it once and does its own synchronisation.
    private struct CompletionSink<T>: @unchecked Sendable {
        private let handler: (T) -> Void
        init(_ handler: @escaping (T) -> Void) { self.handler = handler }
        func callAsFunction(_ value: T) { handler(value) }
    }

    /// The gallery (`isPreview`) shows the user's *own* upcoming events, so the preview is a
    /// truthful picture of what they're about to add. It falls back to the invented sample
    /// only when there is nothing real to show — calendar access not granted yet, or an
    /// empty horizon — because the gallery is no place for the "no access" state.
    private func makeSnapshot(family: WidgetFamily, isPreview: Bool) async -> AgendaEntry {
        let now = Date()
        let (grouped, authorization) = await load()
        if isPreview, CalendarPreferences.isEnabled {
            let hasRealContent = grouped.contains { !$0.items.isEmpty }
            guard authorization.canRead, hasRealContent else { return .sample(referenceDate: now) }
        }
        return entry(asOf: now, grouped: grouped, authorization: authorization, family: family)
    }

    private func makeTimeline(family: WidgetFamily) async -> Timeline<AgendaEntry> {
        let now = Date()
        let (grouped, authorization) = await load()

        let dates = refreshDates(after: now, grouped: grouped, family: family)
        let entries = dates.map {
            entry(asOf: $0, grouped: grouped, authorization: authorization, family: family)
        }
        // Re-generate shortly after the last precomputed entry (never .atEnd, §8).
        let reloadAt = (dates.last ?? now).addingTimeInterval(60)
        return Timeline(entries: entries, policy: .after(reloadAt))
    }

    // MARK: - Fetch + group (once per generation)

    /// Settings come from the App Group, not the (empty) configuration intent — the app is
    /// the only place they're edited (§11).
    private func load() async -> (grouped: [DaySection], auth: CalendarAuthorization) {
        // The switch is checked before `EventKitSource.authorization`, so a user who
        // never enabled the feature has no EventKit call made on their behalf at all —
        // not even a status read — and sees no permission prompt from adding the widget.
        guard CalendarPreferences.isEnabled else { return ([], .notDetermined) }
        let authorization = EventKitSource.authorization
        guard authorization.canRead else { return ([], authorization) }

        let options = WidgetOptionsStore.load()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let daysAhead = options.effectiveDaysAhead
        let end = calendar.date(byAdding: .day, value: daysAhead, to: start)
            ?? start.addingTimeInterval(Double(daysAhead) * 86_400)

        let source = EventKitSource(includeAllDay: options.showAllDay, includeDeclined: options.showDeclined)
        do {
            let calendarIDs = try await resolveCalendarIDs(source: source)
            let events = try await source.events(from: start, to: end, calendarIDs: calendarIDs)
            return (DayGrouping.sections(for: events, in: calendar), authorization)
        } catch {
            return ([], authorization)
        }
    }

    // MARK: - One entry, computed as of `asOf`

    private func entry(
        asOf date: Date,
        grouped: [DaySection],
        authorization: CalendarAuthorization,
        family: WidgetFamily
    ) -> AgendaEntry {
        let calendar = Calendar.current
        let referenceDay = calendar.startOfDay(for: date)

        let featureEnabled = CalendarPreferences.isEnabled
        guard featureEnabled, authorization.canRead else {
            return AgendaEntry(date: date, snapshot: AgendaSnapshot(
                authorization: authorization, sections: [], page: 0, isContinuation: false,
                canPageBack: false, canPageForward: false, referenceDay: referenceDay,
                featureEnabled: featureEnabled))
        }

        let metrics = Metrics.forFamily(agendaFamily(family))
        // Days before "today as of this entry" fall off (§8: midnight rollover). Within
        // today, timed events that have already ended are dropped (deliberate) — all-day
        // and still-running events stay.
        let visible = grouped
            .filter { $0.day >= referenceDay }
            .compactMap { section -> DaySection? in
                guard calendar.isDate(section.day, inSameDayAs: referenceDay) else { return section }
                let upcoming = section.items.filter { $0.isAllDay || $0.event.end > date }
                return upcoming.isEmpty ? nil : DaySection(day: section.day, items: upcoming)
            }

        // When today has nothing, page 0 leads with a "TODAY / No Events" block that `fill`
        // doesn't cost — hold that height back so the last row still fits. A continuation
        // page has no such block, so it gets the full budget.
        let todayEmpty = visible.first.map { !calendar.isDate($0.day, inSameDayAs: referenceDay) } ?? true
        let safeBudget = metrics.fillBudget - metrics.fillSafetyMargin
        let page0Budget = safeBudget - (todayEmpty ? metrics.emptyTodayReserve : 0)

        let page0 = fill(from: nil, budget: page0Budget, sections: visible, cost: metrics.rowCost)
        let requestedPage = PageState.currentPage(for: widgetKey(family), now: date, calendar: calendar)

        let snapshot: AgendaSnapshot
        if requestedPage == 1, let cursor = page0.nextCursor {
            let page1 = fill(from: cursor, budget: safeBudget, sections: visible, cost: metrics.rowCost)
            snapshot = AgendaSnapshot(
                authorization: authorization, sections: page1.sections, page: 1,
                isContinuation: page1.isContinuation, canPageBack: true, canPageForward: false,
                referenceDay: referenceDay)
        } else {
            // Page 0 always leads with today, even when today is empty ("No Events").
            snapshot = AgendaSnapshot(
                authorization: authorization,
                sections: withToday(page0.sections, referenceDay: referenceDay, calendar: calendar),
                page: 0,
                isContinuation: false, canPageBack: false, canPageForward: page0.nextCursor != nil,
                referenceDay: referenceDay)
        }
        return AgendaEntry(date: date, snapshot: snapshot)
    }

    /// Guarantees the section list leads with today (an empty section for it if today has
    /// nothing) so the widget always shows "TODAY … / No Events", even on an empty day.
    private func withToday(_ sections: [DaySection], referenceDay: Date, calendar: Calendar) -> [DaySection] {
        if let first = sections.first, calendar.isDate(first.day, inSameDayAs: referenceDay) {
            return sections
        }
        return [DaySection(day: referenceDay, items: [])] + sections
    }

    // MARK: - Refresh boundaries (§8)

    private func refreshDates(after now: Date, grouped: [DaySection], family: WidgetFamily) -> [Date] {
        let calendar = Calendar.current
        var set = Set<Date>([now])

        // Local midnight — mandatory.
        set.insert(calendar.startOfDay(for: now.addingTimeInterval(86_400)))

        // Every event start / end in the next ~8 hours.
        let horizon = now.addingTimeInterval(8 * 3_600)
        for section in grouped {
            for item in section.items {
                for boundary in [item.displayStart, item.displayEnd] where boundary > now && boundary <= horizon {
                    set.insert(boundary)
                }
            }
        }

        // Page snap-back (§7).
        if PageState.currentPage(for: widgetKey(family), now: now, calendar: calendar) != 0,
           let snapBack = PageState.snapBackDate(for: widgetKey(family), calendar: calendar) {
            set.insert(snapBack)
        }

        // Guarantee at least one entry within ~30 min even if nothing else is scheduled.
        set.insert(now.addingTimeInterval(30 * 60))

        return set.sorted()
    }

    // MARK: - Helpers

    private func widgetKey(_ family: WidgetFamily) -> String { VeyrnCalendarWidgetKind + ".\(family)" }

    private func agendaFamily(_ family: WidgetFamily) -> AgendaFamily {
        (family == .systemLarge || family == .systemExtraLarge) ? .large : .medium
    }

    /// `nil` → all calendars. The selection is edited in the app and stored in the App
    /// Group (§11); each saved calendar resolves by identifier, then title+source (§6.5),
    /// so a re-added account doesn't silently blank the widget.
    private func resolveCalendarIDs(source: EventKitSource) async throws -> [String]? {
        let selection = CalendarSelectionStore.load()
        guard !selection.isAll else { return nil }
        let available = try await source.calendars()
        return selection.resolvedIDs(in: available)
    }
}
