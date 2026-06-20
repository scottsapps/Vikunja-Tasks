import SwiftUI
import WidgetKit

struct WatchWidgetEntryView: View {
    let entry: WatchWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                rectangularView
            case .accessoryCircular:
                circularView
            case .accessoryInline:
                inlineView
            case .accessoryCorner:
                cornerView
            default:
                inlineView
            }
        }
        .widgetURL(URL(string: "veyrn://scheduled"))
    }

    // MARK: - Rectangular: due today count

    private var rectangularView: some View {
        let count = entry.todayCount
        return HStack(spacing: 10) {
            Image(systemName: count == 0 ? "checkmark.circle" : "checklist")
                .font(.system(size: 24))
                .foregroundStyle(count == 0 ? .secondary : .primary)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(count == 1 ? "task due today" : "tasks due today")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }

    // MARK: - Circular: count due today

    private var circularView: some View {
        ZStack {
            Circle().strokeBorder(lineWidth: 2).foregroundStyle(.secondary.opacity(0.3))
            VStack(spacing: 0) {
                Text("\(entry.todayCount)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text("due")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Inline: brief text

    private var inlineView: some View {
        let count = entry.todayCount
        let label = count == 0 ? "No tasks due" : "\(count) due today"
        return Label(label, systemImage: count == 0 ? "checkmark.circle" : "checklist")
    }

    // MARK: - Corner: SF symbol + count

    private var cornerView: some View {
        ZStack {
            Image(systemName: "checklist")
            Text("\(entry.todayCount)")
                .font(.system(size: 10, weight: .bold))
        }
        .widgetLabel(entry.todayCount == 0 ? "All done" : "\(entry.todayCount) due")
    }
}
