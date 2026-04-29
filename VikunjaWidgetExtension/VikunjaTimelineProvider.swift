import WidgetKit
import Foundation

struct VikunjaTimelineProvider: TimelineProvider {

    func placeholder(in context: Context) -> VikunjaEntry {
        VikunjaEntry.placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (VikunjaEntry) -> Void) {
        if context.isPreview {
            completion(VikunjaEntry.placeholder)
            return
        }
        Task { completion(await buildEntry(family: context.family)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VikunjaEntry>) -> Void) {
        Task {
            SharedState.cleanupExpired()
            let entry = await buildEntry(family: context.family)
            let active = SharedState.active

            var entries = [entry]
            let policy: TimelineReloadPolicy

            if !active.isEmpty {
                let earliestCompletion = active.map(\.completedAt).min()!
                let cleanAt = earliestCompletion.addingTimeInterval(SharedState.undoWindow + 0.5)
                entries.append(VikunjaEntry(date: cleanAt, taskGroups: entry.taskGroups, error: nil))
                policy = .after(cleanAt)
            } else {
                let refreshAt = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
                policy = .after(refreshAt)
            }

            completion(Timeline(entries: entries, policy: policy))
        }
    }

    // MARK: - Entry construction

    private func buildEntry(family: WidgetFamily) async -> VikunjaEntry {
        do {
            let projects = try await VikunjaAPI.fetchAllProjects()
            let rawTasks = try await VikunjaAPI.fetchAllUndoneTasks(projects: projects)
            WidgetCache.save(tasks: rawTasks, projects: projects)
            let allItems = makeItems(tasks: rawTasks, projects: projects)
            let grouped = group(allItems)
            return VikunjaEntry(date: Date(), taskGroups: cap(grouped, max: maxTasks(family: family, sectionCount: grouped.count)), error: nil)
        } catch {
            if let cached = WidgetCache.load() {
                let allItems = makeItems(tasks: cached.tasks, projects: cached.projects)
                let grouped = group(allItems)
                return VikunjaEntry(date: Date(), taskGroups: cap(grouped, max: maxTasks(family: family, sectionCount: grouped.count)), error: nil)
            }
            return VikunjaEntry(date: Date(), taskGroups: [], error: error.localizedDescription)
        }
    }

    // MARK: - Item mapping

    private func makeItems(tasks: [VikunjaTask], projects: [VikunjaProject]) -> [TaskEntryItem] {
        let projectMap = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.title) })
        let pendingUndos = SharedState.active
        let pendingIds = Set(pendingUndos.map(\.taskId))

        var allItems: [TaskEntryItem] = tasks.compactMap { task -> TaskEntryItem? in
            guard !pendingIds.contains(task.id), let dueDate = task.effectiveDueDate else { return nil }
            return TaskEntryItem(
                id: task.id,
                title: task.title,
                projectName: projectMap[task.projectId] ?? "Inbox",
                tags: task.labels?.map(\.title) ?? [],
                dueDate: dueDate
            )
        }

        let undoItems = pendingUndos.map {
            TaskEntryItem(id: $0.taskId, title: $0.title, projectName: $0.projectName,
                          tags: $0.tags, dueDate: $0.dueDate, isPendingUndo: true)
        }
        allItems.append(contentsOf: undoItems)
        return allItems
    }

    // MARK: - Date grouping

    private func group(_ tasks: [TaskEntryItem]) -> [TaskGroup] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!

        var buckets: [Date: [TaskEntryItem]] = [:]
        for task in tasks {
            let day = cal.startOfDay(for: task.dueDate)
            let bucket = day < today ? today : day
            buckets[bucket, default: []].append(task)
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "EEE, MMM d"

        return buckets.keys.sorted().compactMap { day -> TaskGroup? in
            let sorted = buckets[day]!.sorted { $0.title.lowercased() < $1.title.lowercased() }
            let label: String
            if day == today { label = "Today" }
            else if day == tomorrow { label = "Tomorrow" }
            else { label = fmt.string(from: day) }
            return TaskGroup(label: label, tasks: sorted)
        }
    }

    private func cap(_ groups: [TaskGroup], max: Int) -> [TaskGroup] {
        var budget = max
        var result: [TaskGroup] = []
        for group in groups {
            guard budget > 0 else { break }
            let visible = Array(group.tasks.prefix(budget))
            result.append(TaskGroup(label: group.label, tasks: visible))
            budget -= visible.count
        }
        return result
    }

    private func maxTasks(family: WidgetFamily, sectionCount: Int = 0) -> Int {
        if family == .systemMedium { return sectionCount >= 2 ? 3 : 4 }
        // Reduce by one when there are 3 section headers — they consume ~1 task-row each.
        return sectionCount >= 3 ? 7 : 8
    }
}
