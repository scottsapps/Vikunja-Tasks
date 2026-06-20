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
    }

    private var supportedFamilies: [WidgetFamily] {
        #if os(iOS)
        return [
            .systemSmall,
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
