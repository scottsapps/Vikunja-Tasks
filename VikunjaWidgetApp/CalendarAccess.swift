//
//  CalendarAccess.swift
//  VikunjaWidgetApp
//
//  The master switch for the calendar layer, and the model behind the settings
//  section. Ported from Calvane's `CalendarModel`, minus the preview tab it also
//  fed — see `skill/references/calendar.md`.
//
//  Two rules this file exists to enforce:
//
//  1. **Nothing touches EventKit until the user asks.** `CalendarPreferences.enabled`
//     is off by default and every read path checks it first, so a user who never
//     flips the switch never sees a permission prompt. That posture is what keeps
//     App Review guideline 5.1.1 quiet — a prompt has to have a visible cause.
//  2. **The app requests access; the widget never does.** A widget extension that
//     prompts is a prompt from nowhere. The extension reads whatever access the app
//     already established and renders a "turn this on in Veyrn" state otherwise.
//

import Foundation
import Observation
import EventKit
import WidgetKit

@MainActor
@Observable
final class CalendarAccessModel {
    private(set) var authorization: CalendarAuthorization = EventKitSource.authorization
    private(set) var calendars: [CalendarInfo] = []
    private(set) var loadError: String?

    var selection: CalendarSelection = CalendarSelectionStore.load()
    var options: WidgetOptions = WidgetOptionsStore.load()

    /// Created lazily so that merely constructing the model can't trip the prompt —
    /// see rule 1. Nil until the user has enabled the feature.
    private var store: EKEventStore?

    /// Ask for calendar access, then load. The only place in Veyrn that prompts.
    func requestAccessAndLoad() async {
        let store = store ?? EKEventStore()
        self.store = store
        do {
            let granted = try await store.requestFullAccessToEvents()
            VeyrnTelemetry.signal("Calendar.accessRequested", parameters: ["result": granted ? "granted" : "denied"])
        } catch {
            VeyrnTelemetry.signal("Calendar.accessRequested", parameters: ["result": "denied"])
            // A denial isn't an error worth showing as one — `authorization` below
            // already says so, and the section renders the denied state.
            DiagnosticLog.info("calendar access request finished without grant")
        }
        await load()
    }

    /// Refresh authorization, the calendar list and the stored settings. Safe to call
    /// when the feature is off: it clears state and returns without touching EventKit.
    func load() async {
        guard CalendarPreferences.isEnabled else {
            authorization = EventKitSource.authorization
            calendars = []
            loadError = nil
            return
        }
        authorization = EventKitSource.authorization
        selection = CalendarSelectionStore.load()
        options = WidgetOptionsStore.load()
        guard authorization.canRead else {
            calendars = []
            return
        }
        do {
            let source = EventKitSource(includeAllDay: options.showAllDay,
                                        includeDeclined: options.showDeclined)
            calendars = try await source.calendars()
            loadError = nil
        } catch {
            // No event titles, no calendar names — calendar data is user content and
            // the diagnostic log's privacy rule covers it. The type of failure is
            // enough to act on.
            loadError = error.localizedDescription
            DiagnosticLog.error("calendar list failed: \(VeyrnError.logDescription(for: error))")
            calendars = []
        }
    }

    // MARK: - Calendar selection

    func setIncluded(_ info: CalendarInfo, _ included: Bool) {
        applySelection(selection.setting(info, included: included, among: calendars))
    }

    func setAll(_ included: Bool) {
        applySelection(included ? .all : CalendarSelection(refs: []))
    }

    private func applySelection(_ new: CalendarSelection) {
        guard new != selection else { return }
        selection = new
        CalendarSelectionStore.save(new)
        nudgeWidgetAndReload()
    }

    // MARK: - Options

    func updateOptions(_ transform: (inout WidgetOptions) -> Void) {
        var new = options
        transform(&new)
        guard new != options else { return }
        options = new
        WidgetOptionsStore.save(new)
        nudgeWidgetAndReload()
    }

    private func nudgeWidgetAndReload() {
        WidgetCenter.shared.reloadTimelines(ofKind: VeyrnCalendarWidgetKind)
        Task { await load() }
    }
}
