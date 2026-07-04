import SwiftUI
import WidgetKit

struct VikunjaWidgetEntryView: View {
    let entry: VikunjaEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(contentPadding)
            .containerBackground(.background, for: .widget)
    }

    private var contentPadding: EdgeInsets {
        #if os(macOS)
        return EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        #else
        switch family {
        case .systemMedium:
            return EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        case .accessoryRectangular, .accessoryCircular, .accessoryInline:
            return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        default:
            return EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        switch family {
        case .accessoryRectangular:
            accessoryRectangularView
        case .accessoryCircular:
            accessoryCircularView
        case .accessoryInline:
            accessoryInlineView
        default:
            systemContent
        }
        #else
        systemContent
        #endif
    }

    // MARK: - System (large/medium) content

    private var systemContent: some View {
        Group {
            if let error = entry.error {
                errorView(error)
            } else if entry.taskGroups.isEmpty {
                emptyView
            } else {
                taskListView
            }
        }
    }

    // MARK: - Accessory: Rectangular (2 tasks)

    #if os(iOS)
    private var accessoryRectangularView: some View {
        let tasks = entry.taskGroups.flatMap(\.tasks).prefix(2)
        return VStack(alignment: .leading, spacing: 2) {
            if tasks.isEmpty {
                Label("No upcoming tasks", systemImage: "checkmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(tasks)) { task in
                    HStack(spacing: 4) {
                        Circle()
                            .stroke(lineWidth: 1.2)
                            .frame(width: 10, height: 10)
                        Text(task.title)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Accessory: Circular (count of today's tasks)

    private var accessoryCircularView: some View {
        let todayCount = entry.todayCount
        return ZStack {
            Circle().strokeBorder(lineWidth: 2).foregroundStyle(.secondary.opacity(0.3))
            VStack(spacing: 0) {
                Text("\(todayCount)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("due")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Accessory: Inline (brief text)

    private var accessoryInlineView: some View {
        let count = entry.todayCount
        if count == 0 {
            return Text("No tasks due today")
        } else {
            return Text("\(count) due today")
        }
    }
    #endif

    // MARK: - Task list (system families)

    private var taskListView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entry.taskGroups.enumerated()), id: \.element.label) { index, group in
                sectionHeader(group.label, isFirst: index == 0)
                ForEach(group.tasks) { task in
                    TaskRowView(task: task)
                        .padding(.vertical, 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func sectionHeader(_ label: String, isFirst: Bool) -> some View {
        Text(label.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.top, isFirst ? 0 : 8)
            .padding(.bottom, 3)
    }

    // MARK: - Empty / error

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No upcoming tasks")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("Couldn't load tasks")
                .font(.subheadline).fontWeight(.medium)
            Text(message)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
