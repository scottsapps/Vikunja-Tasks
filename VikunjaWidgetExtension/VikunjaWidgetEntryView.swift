import SwiftUI
import WidgetKit

struct VikunjaWidgetEntryView: View {
    let entry: VikunjaEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        GeometryReader { geo in
            let inset = contentPadding
            let innerWidth = max(0, geo.size.width - inset.leading - inset.trailing)
            let innerHeight = max(0, geo.size.height - inset.top - inset.bottom)
            content
                .frame(width: innerWidth, height: innerHeight, alignment: .topLeading)
                .clipped()
                .padding(inset)
        }
        .containerBackground(.background, for: .widget)
    }

    private var contentPadding: EdgeInsets {
        #if os(macOS)
        return EdgeInsets(top: 20, leading: 8, bottom: 20, trailing: 8)
        #else
        if family == .systemMedium {
            return EdgeInsets(top: 14, leading: 6, bottom: 14, trailing: 6)
        }
        // Match macOS top/bottom so the first section header and last task
        // aren't clipped by the widget's rounded-corner chrome on iOS.
        return EdgeInsets(top: 20, leading: 12, bottom: 20, trailing: 12)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if let error = entry.error {
            errorView(error)
        } else if entry.taskGroups.isEmpty {
            emptyView
        } else {
            taskListView
        }
    }

    // MARK: - Task list

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
