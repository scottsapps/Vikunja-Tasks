import Foundation
import Observation

@Observable
final class WatchStore {
    var tasks: [VikunjaTask] = []
    var projects: [VikunjaProject] = []
    var labels: [VikunjaLabel] = []
    var isLoading = false
    var errorMessage: String?

    var inboxProject: VikunjaProject? {
        projects.first { $0.title.lowercased() == "inbox" }
    }

    func refresh() async {
        guard VikunjaConfig.isConfigured else { return }
        isLoading = true
        errorMessage = nil
        do {
            let p = try await VikunjaAPI.fetchAllProjects()
            let t = try await VikunjaAPI.fetchAllUndoneTasks(projects: p)
            projects = p
            tasks = t
            if let l = try? await VikunjaAPI.fetchLabels() { labels = l }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Scheduled view

    struct DayGroup: Identifiable {
        let id: Date
        let title: String
        let tasks: [VikunjaTask]
    }

    func scheduledGroups(now: Date = Date()) -> [DayGroup] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard let end = cal.date(byAdding: .day, value: 7, to: today) else { return [] }
        let dated = tasks.compactMap { task -> (Date, VikunjaTask)? in
            guard let due = task.effectiveDueDate else { return nil }
            let day = cal.startOfDay(for: due)
            let bucket = day < today ? today : day
            guard bucket < end else { return nil }
            return (bucket, task)
        }
        let byDay = Dictionary(grouping: dated, by: { $0.0 })
        return byDay.keys.sorted().map { day in
            let items = byDay[day]!.map { $0.1 }
                .sorted { ($0.effectiveDueDate ?? .distantPast) < ($1.effectiveDueDate ?? .distantPast) }
            return DayGroup(id: day, title: Self.dayTitle(day, today: today, cal: cal), tasks: items)
        }
    }

    private static func dayTitle(_ day: Date, today: Date, cal: Calendar) -> String {
        if cal.isDate(day, inSameDayAs: today) { return "Today" }
        if let tom = cal.date(byAdding: .day, value: 1, to: today),
           cal.isDate(day, inSameDayAs: tom) { return "Tomorrow" }
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f.string(from: day)
    }

    func inboxTasks() -> [VikunjaTask] {
        guard let inbox = inboxProject else { return [] }
        return tasks.filter { $0.projectId == inbox.id }
    }

    // MARK: - Mutations (optimistic)

    func complete(_ task: VikunjaTask) async {
        let snapshot = tasks
        tasks.removeAll { $0.id == task.id }
        do {
            try await VikunjaAPI.completeTask(id: task.id)
        } catch {
            tasks = snapshot
            errorMessage = "Couldn't complete. Tap to retry."
        }
    }

    func create(from result: QuickAddResult) async {
        let projectId = resolveProjectId(result.projectName)
        do {
            let labelIds = try await resolveLabelIds(result.labelTitles)
            _ = try await VikunjaAPI.createTask(
                projectId: projectId,
                title: result.cleanedTitle,
                dueDate: result.dueDate,
                priority: result.priority,
                labelIds: labelIds,
                repeatAfter: result.repeatAfter,
                repeatMode: result.repeatMode)
            await refresh()
        } catch {
            errorMessage = "Couldn't create task."
        }
    }

    private func resolveProjectId(_ name: String?) -> Int {
        if let name, let p = projects.first(where: { $0.title.lowercased().hasPrefix(name.lowercased()) }) {
            return p.id
        }
        return inboxProject?.id ?? projects.first?.id ?? 1
    }

    private func resolveLabelIds(_ titles: [String]) async throws -> [Int] {
        var ids: [Int] = []
        for title in titles {
            let lower = title.lowercased()
            if let exact = labels.first(where: { $0.title.lowercased() == lower }) {
                ids.append(exact.id)
            } else if let prefix = labels.first(where: { $0.title.lowercased().hasPrefix(lower) }) {
                ids.append(prefix.id)
            } else {
                let created = try await VikunjaAPI.createLabel(title: title)
                labels.append(created)
                ids.append(created.id)
            }
        }
        return ids
    }
}
