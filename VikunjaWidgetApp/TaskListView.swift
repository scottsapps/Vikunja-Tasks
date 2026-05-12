import SwiftUI

// MARK: - Grouping modes

enum GroupingMode {
    case byDate       // Today / Tomorrow / EEE, MMM d — for Today & project views
    case noGrouping   // flat list — for Inbox
    case byCompletionDate // for Logbook
}

// MARK: - TaskListView

struct TaskListView: View {
    var tasks: [VikunjaTask]
    var mode: GroupingMode
    @Environment(TaskStore.self) private var store

    // Tag filter (used by project view)
    var activeTagFilter: Set<String> = []
    var suppressUpcomingDueDate: Bool = false

    // Inline editor state — which task is expanded
    @State private var expandedTaskId: Int? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            if filteredTasks.isEmpty {
                emptyState
            } else {
                switch mode {
                case .byDate:
                    byDateContent
                case .noGrouping:
                    flatContent
                case .byCompletionDate:
                    logbookContent
                }
            }

            // Undo toast — shows when a task was just completed
            if !store.pendingUndo.isEmpty {
                undoBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 12)
                    .padding(.horizontal, 16)
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.pendingUndo.isEmpty)
    }

    // MARK: - Undo bar

    private var undoBar: some View {
        HStack(spacing: 12) {
            let names = store.pendingUndo.values.map(\.title)
            let label = names.count == 1
                ? "\"\(names[0])\" completed"
                : "\(names.count) tasks completed"
            Text(label)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button("Undo") {
                withAnimation {
                    for id in store.pendingUndo.keys {
                        store.undoComplete(taskId: id)
                    }
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.orange)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 6, y: 2)
    }

    // MARK: - Filtered tasks

    private var filteredTasks: [VikunjaTask] {
        guard !activeTagFilter.isEmpty else { return tasks }
        return tasks.filter { task in
            let taskTags = Set(task.labels?.map(\.title) ?? [])
            return activeTagFilter.isSubset(of: taskTags)
        }
    }

    // MARK: - By-date grouped content

    private var byDateContent: some View {
        let groups = dateGroups(filteredTasks)
        return List {
            ForEach(groups, id: \.label) { group in
                Section {
                    ForEach(group.tasks, id: \.id) { task in
                        taskRowOrEditor(task)
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    sectionHeader(group.label)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Flat content (Inbox)

    private var flatContent: some View {
        List {
            ForEach(filteredTasks.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }, id: \.id) { task in
                taskRowOrEditor(task)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Logbook content

    private var logbookContent: some View {
        List {
            ForEach(tasks, id: \.id) { task in
                LogbookRow(
                    task: task,
                    projectName: store.projectMap[task.projectId] ?? "",
                    onReopen: { Task { await store.reopen(task: task) } }
                )
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Row / editor toggle

    @ViewBuilder
    private func taskRowOrEditor(_ task: VikunjaTask) -> some View {
        if expandedTaskId == task.id {
            InlineTaskEditor(task: task) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedTaskId = nil
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            .padding(.vertical, 4)
        } else {
            TaskRow(
                task: task,
                projectName: store.projectMap[task.projectId] ?? "",
                onTap: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandedTaskId = task.id
                    }
                },
                onComplete: { Task { await store.complete(task: task) } },
                suppressUpcomingDueDate: suppressUpcomingDueDate
            )
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ label: String) -> some View {
        Text(label.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private struct DateGroup {
        let label: String
        let sortKey: Date
        let tasks: [VikunjaTask]
    }

    private func dateGroups(_ tasks: [VikunjaTask]) -> [DateGroup] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!

        var buckets: [Date: [VikunjaTask]] = [:]

        for task in tasks {
            if let due = task.effectiveDueDate {
                let day = cal.startOfDay(for: due)
                let bucket = day < today ? today : day
                buckets[bucket, default: []].append(task)
            } else {
                // Tasks without due date go into a "No Date" bucket keyed by .distantFuture
                buckets[.distantFuture, default: []].append(task)
            }
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "EEE, MMM d"

        return buckets.keys.sorted().compactMap { day -> DateGroup? in
            let sorted = buckets[day]!.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
            let label: String
            if day == .distantFuture { label = "No Date" }
            else if day == today { label = "Today" }
            else if day == tomorrow { label = "Tomorrow" }
            else { label = fmt.string(from: day) }
            return DateGroup(label: label, sortKey: day, tasks: sorted)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: mode == .byCompletionDate ? "archivebox" : "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        switch mode {
        case .byDate: return "Nothing due"
        case .noGrouping: return "Inbox is empty"
        case .byCompletionDate: return "Nothing completed yet"
        }
    }
}
