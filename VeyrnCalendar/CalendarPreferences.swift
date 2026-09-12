//
//  CalendarPreferences.swift
//  VeyrnCalendar
//
//  The master switch and the widget's kind string. **Lives here, not in
//  `VikunjaWidgetApp/`, because the widget extension is a separate process that needs
//  both** — the extension to declare its kind and to decide whether to render events
//  at all, the app to write the switch and nudge the right timelines.
//

import Foundation

/// The master toggle, read from both the app and the widget extension.
enum CalendarPreferences {
    static let enabledKey = "veyrn.calendar.enabled"

    /// **The App Group is the only place this value lives.** The settings toggle binds
    /// straight to this store and the widget extension reads the same key, so there is
    /// no second copy to drift.
    ///
    /// It was briefly a `UserDefaults.standard` value mirrored into the group on change.
    /// That has a silent failure mode worth not re-introducing: if the two ever
    /// disagree, the switch reads *on* while every read path sees *off*, so the feature
    /// is dead and the UI says it is working.
    static var store: UserDefaults? { UserDefaults(suiteName: VikunjaConfig.appGroupSuite) }

    /// Off by default. See rule 1 above.
    static var isEnabled: Bool { store?.bool(forKey: enabledKey) ?? false }

    /// Whether events also appear alongside tasks in the Scheduled list.
    ///
    /// Deliberately **separate from `isEnabled`**: wanting the calendar widget is not
    /// the same as wanting events interleaved into your task list, and someone who
    /// turns the feature on for the widget should not have their Scheduled view
    /// rearranged as a side effect. Only meaningful while `isEnabled` is true.
    static let showInScheduledKey = "veyrn.calendar.showInScheduled"

    /// Defaults to **true** so the switch behaves the way it did when there was only
    /// one of them — turning the calendar on shows events in both places, and this is
    /// the opt-*out*.
    static var showsInScheduled: Bool {
        guard let store else { return true }
        // `bool(forKey:)` cannot distinguish "false" from "never set", and the default
        // here is true, so check for the key's presence first.
        guard store.object(forKey: showInScheduledKey) != nil else { return true }
        return store.bool(forKey: showInScheduledKey)
    }
}

/// The widget's kind string. Lives here rather than in the extension because both
/// processes need it — the app to nudge, the extension to declare.
///
/// **Never `"VikunjaWidget"`**: every installed task widget is bound to that one.
let VeyrnCalendarWidgetKind = "VeyrnCalendarWidget"
