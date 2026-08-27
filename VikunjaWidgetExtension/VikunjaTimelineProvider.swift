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
                entries.append(VikunjaEntry(date: cleanAt, taskGroups: entry.taskGroups, error: nil,
                                            todayCount: entry.todayCount, pageOffset: entry.pageOffset))
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

        // Paging. The offset expires on its own (see WidgetPageState), and is
        // clamped here as well: tasks completed on a later page can shrink the
        // list out from under it, and a page past the end would render empty.
        let familyKey = String(describing: family)
        var offset = WidgetPageState.offset(for: familyKey)
        if offset >= grouped.reduce(0, { $0 + $1.tasks.count }) {
            if offset > 0 { WidgetPageState.reset(for: familyKey) }
            offset = 0
        }
        let page = offset > 0 ? TaskGroup.drop(grouped, first: offset) : grouped

        return VikunjaEntry(
            date: Date(),
            taskGroups: cap(page, family: family),
            error: nil,
            todayCount: todayCount(allItems),
            pageOffset: offset
        )
    }

    private func loggedEntry(tasks: [VikunjaTask], projects: [VikunjaProject], family: WidgetFamily) -> VikunjaEntry {
        let e = entry(tasks: tasks, projects: projects, family: family)
        let itemCount = e.taskGroups.reduce(0) { $0 + $1.tasks.count }
        let page = e.pageOffset > 0 ? ", from offset \(e.pageOffset)" : ""
        DiagnosticLog.info("entry: \(itemCount) items in \(e.taskGroups.count) groups\(page)")
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
                dueDate: dueDate,
                priority: task.priority ?? 0,
                hasReminder: task.hasFutureReminder
            )
        }

        let undoItems = pendingUndos.map {
            TaskEntryItem(id: $0.taskId, title: $0.title, projectName: $0.projectName,
                          tags: $0.tags, dueDate: $0.dueDate,
                          priority: $0.priority ?? 0, hasReminder: $0.hasReminder ?? false,
                          isPendingUndo: true)
        }
        allItems.append(contentsOf: undoItems)
        return allItems
    }

    // MARK: - Date grouping

    private func group(_ tasks: [TaskEntryItem]) -> [TaskGroup] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        var buckets: [Date: [TaskEntryItem]] = [:]
        for task in tasks {
            let day = cal.startOfDay(for: task.dueDate)
            let bucket = day < today ? today : day
            buckets[bucket, default: []].append(task)
        }

        return buckets.keys.sorted().compactMap { day -> TaskGroup? in
            let sorted = buckets[day]!.sorted { $0.title.lowercased() < $1.title.lowercased() }
            return TaskGroup(label: DayLabel.groupHeader(day), tasks: sorted, isToday: day == today)
        }
    }

    // Upper bound only. The canvas is a fixed height, but how much of it a
    // task costs depends on the device's widget size and on whether the title
    // wraps, so the *fitting* is done by the entry view with `ViewThatFits`,
    // which measures real laid-out rows instead of estimating points. This
    // just keeps the entry (and the archived view, which carries one candidate
    // layout per count) from growing without bound: enough rows to overfill
    // the largest canvas, and no more.
    private func cap(_ groups: [TaskGroup], family: WidgetFamily) -> [TaskGroup] {
        let maxItems: Int
        switch family {
        case .systemMedium: maxItems = 8
        default: maxItems = 12
        }
        return TaskGroup.prefix(groups, limit: maxItems)
    }
}

// MARK: - Timeout helper

private struct WidgetTimeoutError: Error {}

/// Races `op` against a **wall-clock** deadline.
///
/// The deadline has to be wall-clock because a single `Task.sleep` for the
/// whole duration does not advance while the Mac is asleep, so it never fires
/// for the one case that most needs it. On build 74 a timeline request that
/// began just before a closed-lid sleep stayed outstanding for 17½ minutes
/// against this supposed 10 s cap, and the extension was killed before it
/// could fall back to the stale cache — so WidgetKit got no entry *and* no
/// reload policy, which is a widget that stops updating until something else
/// pokes it.
///
/// Sleeping in short hops instead fixes that: the tick doesn't advance during
/// system sleep either, but the first one after the machine wakes compares
/// against `Date()`, sees the deadline long gone, and gives up immediately.
private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ op: @escaping @Sendable () async throws -> T
) async throws -> T {
    let deadline = Date().addingTimeInterval(seconds)
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            throw WidgetTimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
