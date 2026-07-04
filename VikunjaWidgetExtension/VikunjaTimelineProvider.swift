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
                entries.append(VikunjaEntry(date: cleanAt, taskGroups: entry.taskGroups, error: nil, todayCount: entry.todayCount))
                policy = .after(cleanAt)
            } else {
                let refreshAt = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
                policy = .after(refreshAt)
            }

            completion(Timeline(entries: entries, policy: policy))
        }
    }

    // MARK: - Entry construction

    private func buildEntry(family: WidgetFamily) async -> VikunjaEntry {
        // 1. Fresh cache → no network at all. The app writes the cache on
        //    every refresh (and iOS background refresh does too), so this is
        //    the common path and keeps the extension well inside WidgetKit's
        //    time budget.
        if let cached = WidgetCache.load(),
           let savedAt = WidgetCache.savedAt,
           Date().timeIntervalSince(savedAt) < 5 * 60 {
            return entry(tasks: cached.tasks, projects: cached.projects, family: family)
        }
        // 2. Network, hard-capped at 10 s so the system never kills us mid-fetch.
        do {
            let (projects, tasks) = try await withTimeout(seconds: 10) {
                let p = try await VikunjaAPI.fetchAllProjects()
                let t = try await VikunjaAPI.fetchAllUndoneTasks(projects: p)
                return (p, t)
            }
            WidgetCache.save(tasks: tasks, projects: projects)
            return entry(tasks: tasks, projects: projects, family: family)
        } catch {
            // 3. Stale cache beats a blank widget.
            if let cached = WidgetCache.load() {
                return entry(tasks: cached.tasks, projects: cached.projects, family: family)
            }
            return VikunjaEntry(date: Date(), taskGroups: [], error: error.localizedDescription, todayCount: 0)
        }
    }

    private func entry(tasks: [VikunjaTask], projects: [VikunjaProject], family: WidgetFamily) -> VikunjaEntry {
        let allItems = makeItems(tasks: tasks, projects: projects)
        let grouped = group(allItems)
        return VikunjaEntry(
            date: Date(),
            taskGroups: cap(grouped, max: maxTasks(family: family, sectionCount: grouped.count)),
            error: nil,
            todayCount: todayCount(allItems)
        )
    }

    private func todayCount(_ items: [TaskEntryItem]) -> Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return items.filter {
            !$0.isPendingUndo && cal.startOfDay(for: $0.dueDate) <= today
        }.count
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

// MARK: - Timeout helper

private struct WidgetTimeoutError: Error {}

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ op: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw WidgetTimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
