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
}

/// The widget's kind string. Lives here rather than in the extension because both
/// processes need it — the app to nudge, the extension to declare.
///
/// **Never `"VikunjaWidget"`**: every installed task widget is bound to that one.
let VeyrnCalendarWidgetKind = "VeyrnCalendarWidget"
