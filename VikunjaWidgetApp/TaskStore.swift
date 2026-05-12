import Foundation
import Observation
import WidgetKit

@Observable
final class TaskStore {

    // MARK: - Published state

    var undoneTasks: [VikunjaTask] = []
    var doneTasks: [VikunjaTask] = []
    var projects: [VikunjaProject] = []
    var labels: [VikunjaLabel] = []
    var isLoading = false
    var error: String?

    // MARK: - Offline infrastructure

    let outbox = Outbox()
    let reachability = Reachability.shared

    /// Last server-fetched undone tasks before merger is applied.
    private var lastServerUndone: [VikunjaTask] = []

    // MARK: - Init

    init() {
        loadCache()
        observeReachability()
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
            lastServerUndone = fetchedTasks
            if let fetchedLabels = try? await VikunjaAPI.fetchLabels() {
                labels = fetchedLabels
            }
            rebuildMergedTasks()
            saveCache()
            await ReminderScheduler.sync(tasks: undoneTasks)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func refreshLogbook() async {
        guard VikunjaConfig.isConfigured else { return }
        do {
            let serverDone = try await VikunjaAPI.fetchDoneTasks(page: 1)
            let labelDir = labelDirectory
            let merged = TaskMerger.merge(serverTasks: serverDone, ops: outbox.ops, labelDirectory: labelDir)
            doneTasks = merged.filter { $0.done }
                .sorted { ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast) }
        } catch {
            // silently fail — logbook is best-effort
        }
    }

    // MARK: - Merged task rebuild

    private func rebuildMergedTasks() {
        let merged = TaskMerger.merge(
            serverTasks: lastServerUndone,
            ops: outbox.ops,
            labelDirectory: labelDirectory
        )
        undoneTasks = merged.filter { !$0.done }
    }

    private var labelDirectory: [Int: VikunjaLabel] {
        Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })
    }

    // MARK: - Create task (enqueues to outbox)

    func createTask(
        projectId: Int,
        title: String,
        dueDate: Date? = nil,
        priority: Int? = nil,
        labels: [VikunjaLabel] = [],
        reminders: [Date] = [],
        repeatAfter: Int? = nil,
        repeatMode: Int? = nil
    ) {
        let clientId = UUID()
        let placeholderId = outbox.nextPlaceholderId()
        let payload = CreatePayload(
            title: title,
            projectId: projectId,
            dueDate: dueDate,
            priority: priority,
            labels: labels,
            reminders: reminders,
            repeatAfter: repeatAfter,
            repeatMode: repeatMode
        )
        let op = PendingOp(
            id: UUID(),
            timestamp: Date(),
            ref: .client(clientId),
            kind: .create(payload: payload, placeholderId: placeholderId)
        )
        outbox.append(op)
        rebuildMergedTasks()
        Task { await drainOutbox() }
    }

    // MARK: - Project management

    func createProject(title: String) async {
        do {
            let project = try await VikunjaAPI.createProject(title: title)
            projects.append(project)
            projects.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteProject(id: Int) async {
        do {
            try await VikunjaAPI.deleteProject(id: id)
            projects.removeAll { $0.id == id }
            lastServerUndone.removeAll { $0.projectId == id }
            rebuildMergedTasks()
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Update task (enqueues to outbox)

    func update(taskId: Int, with update: TaskUpdate) async {
        let ref = ref(for: taskId)
        let op = PendingOp(
            id: UUID(),
            timestamp: Date(),
            ref: ref,
            kind: .update(update: update)
        )
        outbox.append(op)
        rebuildMergedTasks()
        await drainOutbox()
    }

    // MARK: - Completion with undo

    private(set) var pendingUndo: [Int: VikunjaTask] = [:]
    private var undoTimers: [Int: Task<Void, Never>] = [:]
    let undoWindow: TimeInterval = 4

    func complete(task: VikunjaTask) async {
        undoneTasks.removeAll { $0.id == task.id }
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
        let taskRef = ref(for: task.id)
        let op = PendingOp(
            id: UUID(),
            timestamp: Date(),
            ref: taskRef,
            kind: .complete
        )
        outbox.append(op)
        WidgetCenter.shared.reloadAllTimelines()
        await drainOutbox()
    }

    func reopen(task: VikunjaTask) async {
        doneTasks.removeAll { $0.id == task.id }
        let taskRef = ref(for: task.id)
        let op = PendingOp(
            id: UUID(),
            timestamp: Date(),
            ref: taskRef,
            kind: .reopen
        )
        outbox.append(op)
        WidgetCenter.shared.reloadAllTimelines()
        await drainOutbox()
    }

    // MARK: - Drain outbox

    private var isDraining = false

    func drainOutbox() async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        guard reachability.isOnline, !outbox.ops.isEmpty else { return }
        let snapshot = outbox.ops
        for op in snapshot {
            do {
                switch op.kind {
                case .create(let payload, _):
                    let created = try await VikunjaAPI.createTask(
                        projectId: payload.projectId,
                        title: payload.title,
                        dueDate: payload.dueDate,
                        priority: payload.priority,
                        labelIds: payload.labels.map(\.id),
                        reminders: payload.reminders,
                        repeatAfter: payload.repeatAfter,
                        repeatMode: payload.repeatMode
                    )
                    if case .client(let uuid) = op.ref {
                        outbox.remap(client: uuid, toServer: created.id)
                    }
                case .update(let update):
                    guard let serverId = serverId(for: op.ref) else { continue }
                    _ = try await VikunjaAPI.updateTask(id: serverId, update: update)
                case .complete:
                    guard let serverId = serverId(for: op.ref) else { continue }
                    try await VikunjaAPI.completeTask(id: serverId)
                case .reopen:
                    guard let serverId = serverId(for: op.ref) else { continue }
                    try await VikunjaAPI.reopenTask(id: serverId)
                }
                outbox.remove(id: op.id)
            } catch let error as VikunjaAPI.APIError where error.isClient4xx {
                // Task likely deleted server-side — drop op silently
                outbox.remove(id: op.id)
            } catch {
                // Network/server error — stop draining, retry next time
                break
            }
        }
        await refresh()
    }

    // MARK: - Reachability observation

    private func observeReachability() {
        withObservationTracking {
            _ = reachability.isOnline
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.reachability.isOnline {
                    await self.drainOutbox()
                }
                self.observeReachability()
            }
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
                await self?.drainOutbox()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Private helpers

    /// Returns the TaskRef for a given task id (negative = offline placeholder).
    private func ref(for taskId: Int) -> TaskRef {
        if taskId < 0, let uuid = outbox.clientId(forPlaceholder: taskId) {
            return .client(uuid)
        }
        return .server(taskId)
    }

    /// Returns a server Int id only (nil for still-pending client tasks).
    private func serverId(for ref: TaskRef) -> Int? {
        switch ref {
        case .server(let id): return id
        case .client: return nil
        }
    }

    // MARK: - Cache (UserDefaults — app process only)

    private let tasksCacheKey = "app.cache.undoneTasks"
    private let projectsCacheKey = "app.cache.projects"
    private let labelsCacheKey = "app.cache.labels"

    private func loadCache() {
        if let data = UserDefaults.standard.data(forKey: tasksCacheKey),
           let tasks = try? JSONDecoder().decode([VikunjaTask].self, from: data) {
            undoneTasks = tasks
            // Seed lastServerUndone so rebuildMergedTasks() has the right baseline
            // when the user creates/edits tasks before the first successful network fetch.
            lastServerUndone = tasks
        }
        if let data = UserDefaults.standard.data(forKey: projectsCacheKey),
           let projs = try? JSONDecoder().decode([VikunjaProject].self, from: data) {
            projects = projs
        }
        if let data = UserDefaults.standard.data(forKey: labelsCacheKey),
           let lbls = try? JSONDecoder().decode([VikunjaLabel].self, from: data) {
            labels = lbls
        }
    }

    private func saveCache() {
        UserDefaults.standard.set(try? JSONEncoder().encode(undoneTasks), forKey: tasksCacheKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(projects), forKey: projectsCacheKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(labels), forKey: labelsCacheKey)
        WidgetCache.save(tasks: undoneTasks, projects: projects)
    }
}
