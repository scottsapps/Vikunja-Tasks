import Foundation
import Observation
import WidgetKit

@Observable
final class TaskStore {

    // MARK: - Published state

    var undoneTasks: [VikunjaTask] = []
    var doneTasks: [VikunjaTask] = []
    var projects: [VikunjaProject] = []
    var isLoading = false
    var error: String?

    // MARK: - Init

    init() {
        loadCache()
    }

    // MARK: - Derived helpers

    var projectMap: [Int: String] {
        Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.title) })
    }

    var inboxProject: VikunjaProject? {
        projects.first { $0.title.lowercased() == "inbox" }
    }

    func tasks(for project: VikunjaProject) -> [VikunjaTask] {
        undoneTasks.filter { $0.projectId == project.id }
    }

    func inboxTasks() -> [VikunjaTask] {
        guard let inbox = inboxProject else { return [] }
        return undoneTasks.filter { $0.projectId == inbox.id }
    }

    /// All undone tasks that have a due date — used by the Today view.
    func upcomingTasks() -> [VikunjaTask] {
        undoneTasks.filter { $0.effectiveDueDate != nil }
    }

    // MARK: - Refresh

    func refresh() async {
        guard VikunjaConfig.isConfigured else { return }
        isLoading = true
        error = nil
        do {
            let fetchedProjects = try await VikunjaAPI.fetchAllProjects()
            let fetchedTasks = try await VikunjaAPI.fetchAllUndoneTasks(projects: fetchedProjects)
            projects = fetchedProjects
            undoneTasks = fetchedTasks
            saveCache()
            await ReminderScheduler.sync(tasks: fetchedTasks)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func refreshLogbook() async {
        guard VikunjaConfig.isConfigured else { return }
        do {
            doneTasks = try await VikunjaAPI.fetchDoneTasks(page: 1)
        } catch {
            // silently fail — logbook is best-effort
        }
    }

    // MARK: - Completion with undo

    /// Tasks completed in-app but within the undo window.
    private(set) var pendingUndo: [Int: VikunjaTask] = [:]
    private var undoTimers: [Int: Task<Void, Never>] = [:]
    let undoWindow: TimeInterval = 4

    func complete(task: VikunjaTask) async {
        // Optimistic: hide the task from the list immediately
        undoneTasks.removeAll { $0.id == task.id }
        // Stage for undo
        pendingUndo[task.id] = task
        scheduleUndoExpiry(for: task)
    }

    func undoComplete(taskId: Int) {
        guard let task = pendingUndo[taskId] else { return }
        undoTimers[taskId]?.cancel()
        undoTimers.removeValue(forKey: taskId)
        pendingUndo.removeValue(forKey: taskId)
        undoneTasks.append(task)
    }

    private func scheduleUndoExpiry(for task: VikunjaTask) {
        undoTimers[task.id]?.cancel()
        undoTimers[task.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.undoWindow ?? 4))
            guard !Task.isCancelled, let self else { return }
            await commitCompletion(task: task)
        }
    }

    private func commitCompletion(task: VikunjaTask) async {
        pendingUndo.removeValue(forKey: task.id)
        undoTimers.removeValue(forKey: task.id)
        do {
            try await VikunjaAPI.completeTask(id: task.id)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // Restore on API failure
            undoneTasks.append(task)
        }
    }

    func update(taskId: Int, with update: TaskUpdate) async throws {
        let updated = try await VikunjaAPI.updateTask(id: taskId, update: update)
        if let idx = undoneTasks.firstIndex(where: { $0.id == taskId }) {
            undoneTasks[idx] = updated
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    func reopen(task: VikunjaTask) async {
        doneTasks.removeAll { $0.id == task.id }
        do {
            try await VikunjaAPI.reopenTask(id: task.id)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            doneTasks.append(task)
        }
    }

    // MARK: - Background polling

    private var pollTask: Task<Void, Never>?

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Cache (UserDefaults — app process only)

    private let tasksCacheKey = "app.cache.undoneTasks"
    private let projectsCacheKey = "app.cache.projects"

    private func loadCache() {
        if let data = UserDefaults.standard.data(forKey: tasksCacheKey),
           let tasks = try? JSONDecoder().decode([VikunjaTask].self, from: data) {
            undoneTasks = tasks
        }
        if let data = UserDefaults.standard.data(forKey: projectsCacheKey),
           let projs = try? JSONDecoder().decode([VikunjaProject].self, from: data) {
            projects = projs
        }
    }

    private func saveCache() {
        UserDefaults.standard.set(try? JSONEncoder().encode(undoneTasks), forKey: tasksCacheKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(projects), forKey: projectsCacheKey)
    }
}
