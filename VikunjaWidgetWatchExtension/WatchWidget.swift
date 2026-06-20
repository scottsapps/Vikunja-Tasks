import WidgetKit
import SwiftUI

struct WatchWidget: Widget {
    let kind = "VeyrnWatchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchWidgetProvider()) { entry in
            WatchWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Veyrn Tasks")
        .description("Your next tasks at a glance.")
        .supportedFamilies([
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline,
            .accessoryCorner,
        ])
    }
}
