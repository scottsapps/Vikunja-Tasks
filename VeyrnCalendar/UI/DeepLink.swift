//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/UI/DeepLink.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.
//
//  DeepLink.swift
//  VeyrnCalendar
//
//  Calendar widget → somewhere useful.
//
//  WidgetKit routes `.widgetURL` and `Link` to the *containing* app whatever the scheme,
//  so a bare `calshow:` widget URL just launches Veyrn and stops there.
//
//  iOS: the tap target is instead a `Button(intent: OpenCalendarIntent())`. The system —
//  not the container app — opens the intent's `OpenURLIntent` result, so the tap lands
//  straight in Calendar with no app hop. (Undocumented for custom schemes; Apple only
//  promises universal links, so `.widgetURL` below stays wired as the fallback.)
//
//  macOS: Calendar.app registers no navigable URL scheme — only `webcal` / `ical`, for
//  subscriptions — so there is nothing for `OpenURLIntent` to open and the hop through
//  the app is unavoidable. Calvane could make that hop invisible because it was an
//  `LSUIElement` background app; Veyrn is a normal windowed app, so its window comes
//  forward on the way. See the macOS tap options in the 3.5 plan.
//
//  Both URLs reuse the `vikunja://` scheme Veyrn already registers (Info.plist,
//  `CFBundleURLSchemes`) and are routed in `AppRoot.handleDeepLink`.
//

import Foundation

#if !os(macOS)
/// The URL that lands in Apple Calendar on the given day. `stamp` is seconds since the
/// reference date — the argument `calshow:` takes.
public func calendarLaunchURL(stamp: Int) -> URL {
    URL(string: "calshow:\(stamp)")!
}
#endif

/// The widget-wide tap target for a given day. macOS's only route to Calendar, and the
/// iOS fallback for anything the tap-target button misses.
public func dayDeepLink(_ day: Date) -> URL {
    let stamp = Int(day.timeIntervalSinceReferenceDate)
    return URL(string: "vikunja://calendar/\(stamp)")!
}

/// Sent when calendar access is missing — the app opens its own calendar settings, which
/// is where the master toggle and the system-privacy hand-off live.
public let calendarSettingsDeepLink = URL(string: "vikunja://calendar-settings")!
