//  Vendored from Calvane Widget — Widget/Model/OpenCalendarIntent.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.
//
//  OpenCalendarIntent.swift
//  Widget
//
//  Widget tap → Apple Calendar, without the container-app hop (§9).
//
//  `.widgetURL` / `Link` always route to the *containing* app, which is why a bare
//  `calshow:` widget URL just launches Agenda. An AppIntent run from a widget `Button`
//  instead returns `OpenURLIntent`, which the system opens itself, so the tap lands
//  straight in Calendar.
//

import AppIntents
import Foundation

// macOS has no `calshow:` handler, so there is nothing for this intent to open there —
// the Mac widget relays through the app instead (see DeepLink.swift).
#if !os(macOS)

/// **iOS 18+.** `OpenURLIntent` did not exist at Veyrn's iOS 17 floor — Calvane never
/// met this because it declared iOS 26. On 17 the widget falls back to `.widgetURL`,
/// which routes through the app: one visible hop instead of none. Gate the capability,
/// never the feature.
@available(iOS 18.0, *)
struct OpenCalendarIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Calendar"
    static let isDiscoverable: Bool = false
    static let openAppWhenRun: Bool = false

    /// Seconds since the reference date for the day to show (`calshow:` takes this).
    @Parameter(title: "Day") var stamp: Int

    init() {}

    init(day: Date) {
        self.stamp = Int(day.timeIntervalSinceReferenceDate)
    }

    func perform() async throws -> some IntentResult {
        .result(opensIntent: OpenURLIntent(calendarLaunchURL(stamp: stamp)))
    }
}
#endif
