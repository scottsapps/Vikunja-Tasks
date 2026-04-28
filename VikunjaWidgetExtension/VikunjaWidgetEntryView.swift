import SwiftUI
import WidgetKit

struct VikunjaWidgetEntryView: View {
    let entry: VikunjaEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(.background, for: .widget)
    }

    private var contentPadding: EdgeInsets {
        #if os(macOS)
        return EdgeInsets(top: 20, leading: 8, bottom: 20, trailing: 8)
        #else
        if family == .systemMedium {
            return EdgeInsets(top: 12, leading: 6, bottom: 12, trailing: 6)
        }
        return EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
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
        .padding(contentPadding)
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
