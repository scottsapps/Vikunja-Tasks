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

    /// True while the most recent refresh failed for a transient network
    /// reason (timeout, host unreachable, radio not up yet). Drives the
    /// offline pill — never an alert, since there's nothing to act on and the
    /// cached list is still on screen.
    private(set) var transientRefreshFailure = false

    /// The failure from the most recent `refresh()`, so `refreshWithRetry`
    /// can report it once the retries are exhausted.
    private var lastRefreshError: Error?

    /// Message currently being shown, so a repeating failure (the poll loop
    /// hitting the same dead server every 60s) doesn't re-alert.
    private var lastReportedFailure: String?

    /// Volume control (plan §2): a successful refresh whose counts are
    /// unchanged only logs once every 10 minutes; a change (or failure)
    /// always logs.
    private var lastLoggedRefreshSummary: String?
    private var lastLoggedRefreshAt: Date?

    // MARK: - Offline infrastructure

    private(set) var outbox: Outbox
    let reachability = Reachability.shared

    /// Last server-fetched undone tasks before merger is applied.
    private var lastServerUndone: [VikunjaTask] = []

    // MARK: - Init

    init() {
        outbox = Outbox(accountId: VikunjaConfig.activeAccount?.id)
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
        undoneTasks.filter { $0.projectId == project.id && !$0.isSubtask }
    }

    func inboxTasks() -> [VikunjaTask] {
        guard let inbox = inboxProject else { return [] }
        return undoneTasks.filter { $0.projectId == inbox.id && !$0.isSubtask }
    }

    func upcomingTasks() -> [VikunjaTask] {
        undoneTasks.filter { $0.effectiveDueDate != nil && !$0.isSubtask }
    }

    // MARK: - Refresh

    private var lastRefreshAt: Date?

    /// Launch fires two refreshes ~60 ms apart — `AppRoot.task` and the
    /// `scenePhase == .active` handler, which can't be stale-skipped because
    /// `lastRefreshAt` is still nil. That doubled the fan-out to ~24
    /// simultaneous requests against the server, and the first observed
    /// timeout was one of that pair. One refresh at a time is enough.
    private var isRefreshing = false

    func refresh(deferAlert: Bool = false, reason: String = "manual") async {
        guard VikunjaConfig.isConfigured else {
            DiagnosticLog.info("isConfigured=false")
            return
        }
        guard !isRefreshing else {
            DiagnosticLog.info("refresh skipped (reason: \(reason)) — already in flight")
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        isLoading = true
        error = nil
        transientRefreshFailure = false
        lastRefreshError = nil
        DiagnosticLog.info("refresh start (reason: \(reason))")
        VikunjaAPI.beginRequestBatch()
        let refreshStart = Date()
        do {
            let fetchedProjects = try await VikunjaAPI.fetchAllProjects()
            let fetchedTasks = try await VikunjaAPI.fetchAllUndoneTasks(projects: fetchedProjects)
            projects = fetchedProjects
            lastServerUndone = fetchedTasks
            if let fetchedLabels = try? await VikunjaAPI.fetchLabels() {
                let serverIds = Set(fetchedLabels.map(\.id))
                let localOnly = labels.filter { !serverIds.contains($0.id) }
                labels = fetchedLabels + localOnly
            }
            rebuildMergedTasks()
            saveCache()
            #if os(iOS)
            WatchSessionProvider.shared.pushSnapshot(tasks: undoneTasks, projects: projects)
            #endif
            await ReminderScheduler.sync(tasks: undoneTasks)
            lastRefreshAt = Date()
            lastReportedFailure = nil
            Task { await VeyrnTelemetry.probeServerInfoIfNeeded() }
            logRefreshOk(elapsed: Date().timeIntervalSince(refreshStart))
        } catch {
            lastRefreshError = error
            let tier: String
            if VeyrnError.isCancellation(error) {
                // Our own doing — quitting, switching accounts, tearing down a
                // session. Not a failure: no alert, and not even the pill.
                tier = "cancelled"
            } else if VeyrnError.isConnectivityOnly(error) {
                // Nothing for the user to fix and the cached list is still on
                // screen — show it in the pill, let the poll loop recover.
                transientRefreshFailure = true
                tier = "transient"
            } else if deferAlert && VeyrnError.isRetryable(error) {
                // Launch path: a name-resolution/connection failure while
                // Wi-Fi or a VPN is still coming up. Stay quiet; the caller
                // reports it if the retries run out.
                transientRefreshFailure = true
                tier = "retryable"
            } else {
                report(error)
                tier = "alerting"
            }
            let elapsed = Date().timeIntervalSince(refreshStart)
            DiagnosticLog.warn("refresh failed: \(VeyrnError.logDescription(for: error)) [\(tier)], \(formatDuration(elapsed))")
        }
        isLoading = false
    }

    /// Logs a summary line, subject to the 10-minute quiet rule: a refresh
    /// whose counts are unchanged from the last logged one only logs at most
    /// once every 10 minutes, so a healthy 60s poll loop doesn't fill the log.
    private func logRefreshOk(elapsed: TimeInterval) {
        let batch = VikunjaAPI.takeRequestBatch()
        let summary = "\(projects.count) projects, \(undoneTasks.count) undone"
        let changed = summary != lastLoggedRefreshSummary
        let quietElapsed = lastLoggedRefreshAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard changed || quietElapsed >= 600 else { return }
        lastLoggedRefreshSummary = summary
        lastLoggedRefreshAt = Date()
        DiagnosticLog.info("refresh ok: \(summary), \(batch.count) requests, \(formatDuration(elapsed))")
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.1f s", seconds)
    }

    /// Launch-path refresh: retries with backoff so a network stack that isn't
    /// ready yet (Wi-Fi reassociating, VPN handshaking) doesn't surface as a
    /// failure at all. If the retries run out on something the user can
    /// actually fix — a wrong address, a dead server — it's reported then.
    func refreshWithRetry(attempts: Int = 3, reason: String = "launch") async {
        for attempt in 0..<attempts {
            if attempt > 0 {
                DiagnosticLog.info("refreshWithRetry attempt \(attempt + 1)/\(attempts)")
            }
            await refresh(deferAlert: true, reason: reason)
            if !transientRefreshFailure { return }
            if attempt < attempts - 1 {
                try? await Task.sleep(for: .seconds(Double(attempt + 1) * 2))
            }
        }
        if let error = lastRefreshError,
           !VeyrnError.isConnectivityOnly(error),
           !VeyrnError.isCancellation(error) {
            report(error)
        }
    }

    /// Raises a plain-English alert, skipping a failure we're already showing
    /// so the 60s poll loop can't re-raise the same alert over and over.
    private func report(_ error: Error) {
        let message = VeyrnError.message(for: error)
        guard message != lastReportedFailure else { return }
        lastReportedFailure = message
        self.error = message
    }

    /// Refreshes only if the last successful refresh is older than `maxAge`.
    /// Lets foreground/poll triggers pull server-side changes without
    /// hammering the API on every 60s outbox drain.
    func refreshIfStale(maxAge: TimeInterval = 300, reason: String = "manual") async {
        if let last = lastRefreshAt, Date().timeIntervalSince(last) < maxAge {
            let age = Date().timeIntervalSince(last)
            DiagnosticLog.info("refreshIfStale skipped (age \(String(format: "%.0f", age)) s < \(Int(maxAge)) s)")
            return
        }
        await refresh(reason: reason)
    }

    // MARK: - Account switching

    /// Switches the active account and refreshes every piece of state that
    /// would otherwise leak across accounts: in-memory task state, the
    /// outbox (per-account keyed), the widget cache, scheduled reminders,
    /// and (iOS) the Watch's config snapshot. Order matters — see plan §2d.
    @MainActor
    func switchAccount(to id: UUID) async {
        let accounts = VikunjaConfig.accounts
        let fromIndex = accounts.firstIndex(where: { $0.id == VikunjaConfig.activeAccountId }).map { $0 + 1 }
        let toIndex = accounts.firstIndex(where: { $0.id == id }).map { $0 + 1 } ?? 0
        DiagnosticLog.info("switchAccount #\(fromIndex.map(String.init) ?? "?") → #\(toIndex) of \(accounts.count)")

        VikunjaConfig.setActive(id: id)
        resetPerAccountState(accountId: id)

        await ReminderScheduler.cancelAll()
        DiagnosticLog.info("reminders cancelled")
        #if os(iOS)
        WatchSessionProvider.shared.syncConfig()
        DiagnosticLog.info("watch config synced")
        #endif
        VeyrnTelemetry.resetServerInfoGuard()
        VeyrnTelemetry.accountSwitched(accountCount: VikunjaConfig.accounts.count)

        await refreshWithRetry(reason: "switchAccount")
    }

    /// The last account was deleted — same per-account cleanup as
    /// `switchAccount`, but there's nothing to switch to or refresh; the app
    /// falls back to onboarding.
    @MainActor
    func clearForNoAccounts() async {
        DiagnosticLog.info("clearForNoAccounts")
        resetPerAccountState(accountId: nil)

        await ReminderScheduler.cancelAll()
        #if os(iOS)
        WatchSessionProvider.shared.syncConfig()
        #endif
    }

    /// Call after `VikunjaConfig.deleteAccount(id:)` when the deleted account
    /// was the active one — `VikunjaConfig` already reassigned (or cleared)
    /// the active account; this reacts to that at the app layer.
    @MainActor
    func handleAccountDeleted() async {
        DiagnosticLog.info("handleAccountDeleted")
        if let newActive = VikunjaConfig.activeAccount {
            await switchAccount(to: newActive.id)
        } else {
            await clearForNoAccounts()
        }
    }

    private func resetPerAccountState(accountId: UUID?) {
        undoneTasks = []
        doneTasks = []
        projects = []
        labels = []
        lastServerUndone = []
        error = nil
        lastReportedFailure = nil
        lastRefreshError = nil
        transientRefreshFailure = false
        lastRefreshAt = nil

        for timer in undoTimers.values { timer.cancel() }
        undoTimers.removeAll()
        pendingUndo.removeAll()

        outbox = Outbox(accountId: accountId)
        DiagnosticLog.info("outbox replaced")

        WidgetCache.clear()
        WidgetCenter.shared.reloadAllTimelines()
        DiagnosticLog.info("widget cache cleared")
    }

    func refreshLogbook() async {
        guard VikunjaConfig.isConfigured else {
            DiagnosticLog.info("isConfigured=false")
            return
        }
        do {
            let serverDone = try await VikunjaAPI.fetchDoneTasks(page: 1)
            let labelDir = labelDirectory
            let merged = TaskMerger.merge(serverTasks: serverDone, ops: outbox.ops, labelDirectory: labelDir)
            doneTasks = merged.filter { $0.done }
                .sorted { ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast) }
            saveDoneCache()
        } catch {
            // silently fail — logbook is best-effort; keep cached data
        }
    }

    // MARK: - Merged task rebuild

    private func rebuildMergedTasks() {
        let merged = TaskMerger.merge(
            serverTasks: lastServerUndone,
            ops: outbox.ops,
            labelDirectory: labelDirectory
        )
        undoneTasks = merged.filter { !$0.done && pendingUndo[$0.id] == nil }
    }

    private var labelDirectory: [Int: VikunjaLabel] {
        Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })
    }

    // MARK: - Create task (enqueues to outbox)

    func createTask(
        projectId: Int,
        title: String,
        description: String? = nil,
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
            description: description,
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
        VeyrnTelemetry.signal("TaskCreated")
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
            report(error)
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
            report(error)
        }
    }

    // MARK: - Delete task

    func deleteTask(task: VikunjaTask) async {
        DiagnosticLog.info("delete task \(task.id)\(task.id < 0 ? " (placeholder)" : "")")
        undoneTasks.removeAll { $0.id == task.id }
        lastServerUndone.removeAll { $0.id == task.id }
        if task.id > 0 {
            try? await VikunjaAPI.deleteTask(id: task.id)
        }
        await ReminderScheduler.cancel(taskId: task.id, reason: "deleted")
        WidgetCenter.shared.reloadAllTimelines()
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
        DiagnosticLog.info("complete task \(task.id) (undo window open)")
        undoneTasks.removeAll { $0.id == task.id }
        pendingUndo[task.id] = task
        scheduleUndoExpiry(for: task)
    }

    func undoComplete(taskId: Int) {
        guard let task = pendingUndo[taskId] else { return }
        DiagnosticLog.info("undo complete task \(taskId)")
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
        DiagnosticLog.info("commit complete task \(task.id)")
        VeyrnTelemetry.signal("TaskCompleted")
        pendingUndo.removeValue(forKey: task.id)
        undoTimers.removeValue(forKey: task.id)
        var completedTask = task
        completedTask.done = true
        doneTasks.insert(completedTask, at: 0)
        saveDoneCache()
        let taskRef = ref(for: task.id)
        let op = PendingOp(
            id: UUID(),
            timestamp: Date(),
            ref: taskRef,
            kind: .complete
        )
        outbox.append(op)
        await ReminderScheduler.cancel(taskId: task.id, reason: "completed")
        WidgetCenter.shared.reloadAllTimelines()
        await drainOutbox()
    }

    func reopen(task: VikunjaTask) async {
        doneTasks.removeAll { $0.id == task.id }
        saveDoneCache()
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
        DiagnosticLog.info("drain start: \(snapshot.count) ops [\(opCounts(snapshot))]")
        let drainStart = Date()
        var okCount = 0
        var droppedCount = 0
        for op in snapshot {
            do {
                switch op.kind {
                case .create(let payload, _):
                    let created = try await VikunjaAPI.createTask(
                        projectId: payload.projectId,
                        title: payload.title,
                        description: payload.description,
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
                    DiagnosticLog.info("op create task \(created.id) → ok")
                case .update(let update):
                    guard let serverId = serverId(for: op.ref) else { continue }
                    _ = try await VikunjaAPI.updateTask(id: serverId, update: update)
                    DiagnosticLog.info("op update task \(serverId) → ok")
                case .complete:
                    guard let serverId = serverId(for: op.ref) else { continue }
                    try await VikunjaAPI.completeTask(id: serverId)
                    DiagnosticLog.info("op complete task \(serverId) → ok")
                case .reopen:
                    guard let serverId = serverId(for: op.ref) else { continue }
                    try await VikunjaAPI.reopenTask(id: serverId)
                    DiagnosticLog.info("op reopen task \(serverId) → ok")
                case .relation(let parentRef, let childRef, let kind, let add):
                    guard let parentId = serverId(for: parentRef),
                          let childId = serverId(for: childRef) else { continue }
                    if add {
                        try await VikunjaAPI.addRelation(taskId: parentId, otherTaskId: childId, kind: kind)
                    } else {
                        try await VikunjaAPI.removeRelation(taskId: parentId, otherTaskId: childId, kind: kind)
                    }
                    DiagnosticLog.info("op relation task \(parentId) → ok")
                }
                outbox.remove(id: op.id)
                okCount += 1
            } catch let error as VikunjaAPI.APIError where error.isClient4xx {
                // Task likely deleted server-side — drop op silently
                DiagnosticLog.warn("op \(opLabel(op)) → dropped (\(error.statusCode), task gone)")
                outbox.remove(id: op.id)
                droppedCount += 1
            } catch {
                // Network/server error — stop draining, retry next time
                DiagnosticLog.warn("drain paused: \(VeyrnError.logDescription(for: error))")
                break
            }
        }
        let elapsed = Date().timeIntervalSince(drainStart)
        DiagnosticLog.info("drain end: \(okCount) ok, \(droppedCount) dropped, \(formatDuration(elapsed)) — queue depth \(outbox.ops.count)")
        await refresh(reason: "outbox")
    }

    private func opCounts(_ ops: [PendingOp]) -> String {
        var counts: [String: Int] = [:]
        for op in ops {
            switch op.kind {
            case .create: counts["create", default: 0] += 1
            case .update: counts["update", default: 0] += 1
            case .complete: counts["complete", default: 0] += 1
            case .reopen: counts["reopen", default: 0] += 1
            case .relation: counts["relation", default: 0] += 1
            }
        }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    private func opLabel(_ op: PendingOp) -> String {
        switch op.kind {
        case .create: return "create"
        case .update: return "update task \(serverId(for: op.ref).map(String.init) ?? "?")"
        case .complete: return "complete task \(serverId(for: op.ref).map(String.init) ?? "?")"
        case .reopen: return "reopen task \(serverId(for: op.ref).map(String.init) ?? "?")"
        case .relation: return "relation"
        }
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
                await self?.refreshIfStale(reason: "poll")
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
    private let doneTasksCacheKey = "app.cache.doneTasks"

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
        if let data = UserDefaults.standard.data(forKey: doneTasksCacheKey),
           let tasks = try? JSONDecoder().decode([VikunjaTask].self, from: data) {
            doneTasks = tasks
        }
        if let savedAt = WidgetCache.savedAt {
            let age = Date().timeIntervalSince(savedAt)
            DiagnosticLog.info("cache loaded: \(undoneTasks.count) tasks, age \(String(format: "%.0f", age)) s")
        }
    }

    private func saveCache() {
        UserDefaults.standard.set(try? JSONEncoder().encode(undoneTasks), forKey: tasksCacheKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(projects), forKey: projectsCacheKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(labels), forKey: labelsCacheKey)
        WidgetCache.save(tasks: undoneTasks, projects: projects)
        DiagnosticLog.info("widget cache saved: \(undoneTasks.count) tasks, \(projects.count) projects")
    }

    private func saveDoneCache() {
        UserDefaults.standard.set(try? JSONEncoder().encode(doneTasks), forKey: doneTasksCacheKey)
    }
}
