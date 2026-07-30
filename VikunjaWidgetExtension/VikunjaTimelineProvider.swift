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
                DiagnosticLog.info("reload policy: after \(String(format: "%.1f", SharedState.undoWindow + 0.5)) s (undo)")
            } else {
                // The app explicitly reloads timelines whenever data changes, so
                // this self-reload only covers changes made on other devices and
                // the midnight rollover. 15 min keeps the extension's WidgetKit
                // budget usage low — heavy reload churn is what gets a macOS
                // widget parked as a blank placeholder.
                let refreshAt = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
                policy = .after(refreshAt)
                DiagnosticLog.info("reload policy: after 15 m")
            }

            completion(Timeline(entries: entries, policy: policy))
        }
    }

    // MARK: - Entry construction

    private func buildEntry(family: WidgetFamily) async -> VikunjaEntry {
        // Keeps the extension's own log header describing the running build
        // and the current account/server; rewrites only when something changed.
        DiagnosticLog.refreshHeader()
        DiagnosticLog.info("timeline request: family=\(family)")

        // 1. Fresh cache → no network at all. The app writes the cache on
        //    every refresh (and iOS background refresh does too), so this is
        //    the common path and keeps the extension well inside WidgetKit's
        //    time budget. 15 min (not 5) so that while the app is running its
        //    ~5-min poll always beats the window — the widget should only pay
        //    for a network fetch when nothing else is keeping the cache warm.
        if let savedAt = WidgetCache.savedAt {
            let age = Date().timeIntervalSince(savedAt)
            if age < 15 * 60, let cached = WidgetCache.load() {
                DiagnosticLog.info("cache hit: age \(String(format: "%.0f", age)) s, \(cached.tasks.count) tasks (no network)")
                return loggedEntry(tasks: cached.tasks, projects: cached.projects, family: family)
            }
            DiagnosticLog.info("cache stale: age \(String(format: "%.0f", age / 60)) m → live fetch")
        } else {
            DiagnosticLog.info("cache miss")
        }

        guard VikunjaConfig.isConfigured else {
            DiagnosticLog.info("isConfigured=false")
            if let cached = WidgetCache.load() {
                return loggedEntry(tasks: cached.tasks, projects: cached.projects, family: family)
            }
            DiagnosticLog.error("no cache, showing error view")
            return VikunjaEntry(date: Date(), taskGroups: [], error: "Not configured", todayCount: 0)
        }

        // 2. Network, hard-capped at 10 s so the system never kills us mid-fetch.
        let fetchStart = Date()
        do {
            let (projects, tasks) = try await withTimeout(seconds: 10) {
                let p = try await VikunjaAPI.fetchAllProjects()
                let t = try await VikunjaAPI.fetchAllUndoneTasks(projects: p)
                return (p, t)
            }
            DiagnosticLog.info("fetch ok: \(String(format: "%.1f", Date().timeIntervalSince(fetchStart))) s")
            WidgetCache.save(tasks: tasks, projects: projects)
            return loggedEntry(tasks: tasks, projects: projects, family: family)
        } catch {
            // 3. Stale cache beats a blank widget.
            if let cached = WidgetCache.load(), let savedAt = WidgetCache.savedAt {
                let age = Date().timeIntervalSince(savedAt)
                DiagnosticLog.error("fetch \(VeyrnError.logDescription(for: error)) → stale cache (age \(String(format: "%.0f", age / 60)) m)")
                return loggedEntry(tasks: cached.tasks, projects: cached.projects, family: family)
            }
            DiagnosticLog.error("no cache, showing error view")
            return VikunjaEntry(date: Date(), taskGroups: [], error: error.localizedDescription, todayCount: 0)
        }
    }

    private func entry(tasks: [VikunjaTask], projects: [VikunjaProject], family: WidgetFamily) -> VikunjaEntry {
        let allItems = makeItems(tasks: tasks, projects: projects)
        let grouped = group(allItems)
        return VikunjaEntry(
            date: Date(),
            taskGroups: fit(grouped, family: family),
            error: nil,
            todayCount: todayCount(allItems)
        )
    }

    private func loggedEntry(tasks: [VikunjaTask], projects: [VikunjaProject], family: WidgetFamily) -> VikunjaEntry {
        let e = entry(tasks: tasks, projects: projects, family: family)
        let itemCount = e.taskGroups.reduce(0) { $0 + $1.tasks.count }
        DiagnosticLog.info("entry: \(itemCount) items in \(e.taskGroups.count) groups")
        return e
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
            guard !pendingIds.contains(task.id), !task.isSubtask, let dueDate = task.effectiveDueDate else { return nil }
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

    // The widget canvas is a fixed height, so cap by estimated points, not a
    // flat task count: every section header costs ~a row and every wrapped
    // (2-line) title costs ~1.5 rows. A flat cap overflowed the canvas
    // whenever tasks spread across many date sections, blowing through the
    // top/bottom margins (and an oversized layout can fail to render at all).
    private func fit(_ groups: [TaskGroup], family: WidgetFamily) -> [TaskGroup] {
        let budget: CGFloat
        switch family {
        case .systemSmall: budget = 108
        case .systemMedium: budget = 118
        default: budget = 296
        }
        // Rough chars-per-line for the 12pt title before it wraps to 2 lines.
        let wrapThreshold = family == .systemSmall ? 14 : 40

        var used: CGFloat = 0
        var result: [TaskGroup] = []
        for group in groups {
            let headerHeight: CGFloat = result.isEmpty ? 15 : 23
            var visible: [TaskEntryItem] = []
            for task in group.tasks {
                let titleLines: CGFloat = task.title.count > wrapThreshold ? 2 : 1
                let rowHeight = titleLines * 15 + 17  // title + spacing + project/tag line + row padding
                let cost = visible.isEmpty ? headerHeight + rowHeight : rowHeight
                if used + cost > budget {
                    if !visible.isEmpty {
                        result.append(TaskGroup(label: group.label, tasks: visible))
                    }
                    return result
                }
                used += cost
                visible.append(task)
            }
            result.append(TaskGroup(label: group.label, tasks: visible))
        }
        return result
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
