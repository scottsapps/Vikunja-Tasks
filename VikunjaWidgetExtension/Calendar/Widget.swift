//  Vendored from Calvane Widget — Widget/Widget.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.
//
//  Widget.swift
//  Widget
//
//  The second widget in Veyrn's bundle. StaticConfiguration + TimelineProvider — there
//  is nothing to configure on the widget itself (every setting lives in the app's
//  Calendar section), so the "Edit Widget" affordance is gone.
//
//  `VeyrnCalendarWidgetKind` is wired into `SetPageIntent`, `PageState` and every
//  `WidgetCenter` reload. **Never reuse "VikunjaWidget"** — every installed task widget
//  is bound to that one.
//

import WidgetKit
import SwiftUI

struct VeyrnCalendarWidget: Widget {
    let kind = VeyrnCalendarWidgetKind

    /// iOS gets both the two-column medium (§5.5) and the single-column large agenda;
    /// macOS is large-only (§5.6).
    static var supportedFamilies: [WidgetFamily] {
        #if os(macOS)
        [.systemLarge]
        #else
        [.systemMedium, .systemLarge]
        #endif
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AgendaProvider()) { entry in
            AgendaWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Veyrn Calendar")
        .description("Your upcoming events from the calendars on this device, grouped by day.")
        .supportedFamilies(Self.supportedFamilies)
        .contentMarginsDisabled()
    }
}

#Preview("Medium", as: .systemMedium) {
    VeyrnCalendarWidget()
} timeline: {
    AgendaEntry.sample()
}

#Preview("Large", as: .systemLarge) {
    VeyrnCalendarWidget()
} timeline: {
    AgendaEntry.sample()
}
