import WidgetKit
import SwiftUI

struct VikunjaWidget: Widget {
    let kind = "VikunjaWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VikunjaTimelineProvider()) { entry in
            VikunjaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Veyrn Tasks")
        .description("Upcoming tasks from your Veyrn instance.")
        .supportedFamilies(supportedFamilies)
        // The system's default content margins (~16 pt a side) cost the medium
        // widget more than a task row of height and enough width to wrap
        // titles that would otherwise sit on one line. The entry view applies
        // its own insets instead — see VikunjaWidgetEntryView.contentPadding,
        // which re-applies the system values for every family but medium.
        .contentMarginsDisabled()
    }

    private var supportedFamilies: [WidgetFamily] {
        #if os(iOS)
        return [
            .systemMedium,
            .systemLarge,
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline,
        ]
        #else
        return [.systemLarge]
        #endif
    }
}

@main
struct VikunjaWidgetBundle: WidgetBundle {
    var body: some Widget {
        VikunjaWidget()
        // Always offered in the gallery, even with the calendar feature switched off —
        // a widget that appears only once a hidden setting is flipped is the kind of
        // thing guideline 2.3.1 is about. With the switch off it renders a "turn this
        // on in Veyrn" state instead of events, and asks for no permission.
        VeyrnCalendarWidget()
    }
}
