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
    }
}
