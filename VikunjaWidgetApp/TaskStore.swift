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

    /// True when a refresh is in flight and what's on screen predates it by enough
    /// to be worth flagging. Cache-first rendering is deliberate (stale beats
    /// blank), but a list that silently re-reconciles two seconds after you open
    /// the app reads as a glitch — this labels it instead.
    var isShowingStaleData: Bool {
        guard isLoading else { return false }
        guard let last = lastRefreshAt else { return true }
        return Date().timeIntervalSince(last) > 90
    }

    /// Launch fires two refreshes ~60 ms apart — `AppRoot.task` and the
    /// `scenePhase == .active` handler, which can't be stale-skipped because
    /// `lastRefreshAt` is still nil. That doubled the fan-out to ~24
    /// simultaneous requests against the server, and the first observed
    /// timeout was one of that pair. One refresh at a time is enough.
    private var isRefreshing = false

    /// A refresh that arrives while one is running is **coalesced**, not
    /// dropped. Dropping cost real correctness: completing a task drains the
    /// outbox and asks for a reconciling refresh, and if that request landed
    /// during an already-running refresh which had itself been issued *before*
    /// the completion, the stale count stuck around — the widget cache held
    /// one extra task for a full poll cycle. One follow-up pass is enough;
    /// anything arriving during the follow-up sets the flag again for the next
    /// caller rather than looping here.
    ///
    /// **Carries the queued caller's own flags, not the in-flight one's.**
    /// They genuinely differ — the 60 s poll, the post-drain catch-up and the
    /// nudge are `background: true`, while pull-to-refresh, settings-save and
    /// `scenePhase → active` are not — and reusing the running refresh's flags
    /// got the alert policy backwards in both directions: an unattended poll
    /// that landed during a manual refresh could raise a modal alert on a 502
    /// (the `isGatewayFailure` invariant says it must not), and a manual
    /// refresh that landed during a poll had its errors silently demoted to
    /// the pill. Both are observable in the 2026-08-10 iOS log, which coalesces
    /// scenePhase into poll and manual into scenePhase within one minute.
    private var coalescedRefresh: (reason: String, deferAlert: Bool, background: Bool)?

    /// `background` marks a refresh nobody asked for — the 60s poll and the
    /// post-drain catch-up. Nothing is waiting on the result and the cached
    /// list stays on screen, so a server that's briefly unreachable is left to
    /// the next poll instead of raising an alert.
    func refresh(deferAlert: Bool = false, background: Bool = false, reason: String = "manual") async {
        guard VikunjaConfig.isConfigured else {
            DiagnosticLog.info("isConfigured=false")
            return
        }
        guard !isRefreshing else {
            // Several callers can queue behind one refresh, and the single
            // follow-up pass stands in for all of them — so it may only stay
            // quiet if *every* one of them was willing to be. The newest
            // reason wins for the log line; the flags are the conjunction.
            coalescedRefresh = (
                reason: reason,
                deferAlert: (coalescedRefresh?.deferAlert ?? true) && deferAlert,
                background: (coalescedRefresh?.background ?? true) && background
            )
            DiagnosticLog.info("refresh coalesced (reason: \(reason)) — one already in flight")
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        await performRefresh(deferAlert: deferAlert, background: background, reason: reason)

        // Still inside `isRefreshing`, so this can't start a third pass.
        if let queued = coalescedRefresh {
            coalescedRefresh = nil
            await performRefresh(
                deferAlert: queued.deferAlert,
                background: queued.background,
                reason: "\(queued.reason), coalesced"
            )
        }
    }

    private func performRefresh(deferAlert: Bool, background: Bool, reason: String) async {
        isLoading = true
        error = nil
        transientRefreshFailure = false
        lastRefreshError = nil
        DiagnosticLog.info("refresh start (reason: \(reason))")
        VikunjaAPI.beginRequestBatch()
        let refreshClock = DiagnosticLog.Stopwatch()
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
            logRefreshOk(elapsed: DiagnosticLog.elapsed(refreshClock))
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
            } else if background && VeyrnError.isGatewayFailure(error) {
                // A proxy or CDN in front of Vikunja couldn't reach it for a
                // moment. Nothing here is the user's to fix, the cached list is
                // still on screen, and the next poll almost always succeeds —
                // so this stays in the pill. A manual refresh still alerts:
                // there, someone is waiting on an answer.
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
            let elapsed = DiagnosticLog.elapsed(refreshClock)
            DiagnosticLog.warn("refresh failed: \(VeyrnError.logDescription(for: error)) [\(tier)], \(elapsed)")
        }
        isLoading = false
    }

    /// Logs a summary line, subject to the 10-minute quiet rule: a refresh
    /// whose counts are unchanged from the last logged one only logs at most
    /// once every 10 minutes, so a healthy 60s poll loop doesn't fill the log.
    private func logRefreshOk(elapsed: String) {
        let batch = VikunjaAPI.takeRequestBatch()
        let summary = "\(projects.count) projects, \(undoneTasks.count) undone"
        let changed = summary != lastLoggedRefreshSummary
        let quietElapsed = lastLoggedRefreshAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard changed || quietElapsed >= 600 else { return }
        lastLoggedRefreshSummary = summary
        lastLoggedRefreshAt = Date()
        DiagnosticLog.info("refresh ok: \(summary), \(batch.count) requests, \(elapsed)")
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
    func refreshIfStale(maxAge: TimeInterval = 300, background: Bool = false, reason: String = "manual") async {
        if let last = lastRefreshAt, Date().timeIntervalSince(last) < maxAge {
            let age = Date().timeIntervalSince(last)
            DiagnosticLog.info("refreshIfStale skipped (age \(String(format: "%.0f", age)) s < \(Int(maxAge)) s)")
            return
        }
        await refresh(background: background, reason: reason)
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

        // A logbook search belongs to the account that ran it: an in-flight
        // request could otherwise deliver the *old* server's completed tasks
        // after the switch, and already-shown results would linger.
        logbookSearchTask?.cancel()
        logbookSearchTask = nil
        logbookSearchResults = nil

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

    // MARK: - Logbook search (Phase 3, v2 servers only)

    /// Non-nil once a server-side search has returned results for the current
    /// query text — the Logbook prefers these over client-side filtering of
    /// `doneTasks` when present. Nil means "no server search in flight or
    /// available"; the caller falls back to filtering what's already loaded,
    /// exactly as it did before this existed.
    private(set) var logbookSearchResults: [VikunjaTask]?
    private var logbookSearchTask: Task<Void, Never>?

    /// Debounces (~300 ms) and searches the server's entire completion
    /// history via `VikunjaAPI.searchDoneTasks`. On a v1 server, or if the
    /// search fails for any reason (including mid-flight cancellation), falls
    /// back to nil so the caller's existing client-side filter takes over —
    /// old-server users lose nothing and gain nothing.
    func updateLogbookSearch(_ query: String) {
        logbookSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            logbookSearchResults = nil
            return
        }
        // @MainActor: `logbookSearchResults` is observed by SwiftUI, and an
        // unstructured Task in this nonisolated method would otherwise publish
        // it from a background thread (same pattern as `observeReachability`).
        logbookSearchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            do {
                let results = try await VikunjaAPI.searchDoneTasks(query: trimmed)
                guard !Task.isCancelled else { return }
                self?.logbookSearchResults = results
            } catch {
                guard !Task.isCancelled else { return }
                self?.logbookSearchResults = nil
            }
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
            ChangeBeacon.publish(reason: "create project")
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
            ChangeBeacon.publish(reason: "delete project")
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
            // A placeholder delete never reached the server, so only nudge
            // when there was a real task id to delete.
            ChangeBeacon.publish(reason: "delete")
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
        let drainClock = DiagnosticLog.Stopwatch()
        var okCount = 0
        var droppedCount = 0
        // Index walk rather than `for op in snapshot`: on a 2.5.0+ server a run
        // of consecutive same-project creates (a bulk import, or a batch added
        // offline) is swallowed by one atomic request instead of one round trip
        // each. Only *consecutive* ops are coalesced, so ordering against a
        // later update/complete on the same task is unchanged.
        var index = 0
        // One 4xx from the bulk endpoint disables it for the rest of this
        // drain, so a systematically-rejected queue doesn't burn a wasted
        // request per run before falling back.
        var bulkDisabled = false
        while index < snapshot.count {
            let op = snapshot[index]

            if !bulkDisabled, VikunjaAPI.supportsBulkTaskCreate,
               let run = bulkCreateRun(in: snapshot, from: index), run.count >= 2 {
                do {
                    try await performBulkCreate(run)
                    okCount += run.count
                    index += run.count
                    continue
                } catch let error as VikunjaAPI.APIError where error.isClient4xx {
                    // Bulk create is atomic — a 4xx means *nothing* was created,
                    // so replaying these as single creates can't duplicate
                    // anything. Falling back also restores per-op 4xx dropping,
                    // so one bad task can't wedge the queue behind it.
                    DiagnosticLog.warn("bulk create ×\(run.count) → \(error.statusCode), falling back to per-task creates")
                    bulkDisabled = true
                } catch {
                    DiagnosticLog.warn("drain paused: \(VeyrnError.logDescription(for: error))")
                    break
                }
            }

            // Every path below handles exactly one op, and the switch uses
            // `continue` to skip ops whose target task is gone — so the cursor
            // advances here, before the body, not at the bottom of the loop.
            // The bulk branch above advances by its whole run and `continue`s.
            index += 1

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
        let elapsed = DiagnosticLog.elapsed(drainClock)
        DiagnosticLog.info("drain end: \(okCount) ok, \(droppedCount) dropped, \(elapsed) — queue depth \(outbox.ops.count)")
        // Only when something actually landed server-side: a drain that
        // dropped 4xx ops or paused on a network error changed nothing and
        // must not nudge other devices.
        if okCount > 0 { ChangeBeacon.publish(reason: "outbox") }
        await refresh(background: true, reason: "outbox")
    }

    // MARK: - Bulk create (Vikunja 2.5.0+)

    /// The maximal run of consecutive `.create` ops starting at `start` that
    /// all target the same project, capped at the server's per-request limit —
    /// so a 250-task import drains as three accepted bulk requests rather than
    /// one rejected one.
    private func bulkCreateRun(in ops: [PendingOp], from start: Int) -> [PendingOp]? {
        guard case .create(let first, _) = ops[start].kind else { return nil }
        var run: [PendingOp] = []
        var index = start
        while index < ops.count, run.count < VikunjaAPI.bulkCreateMaxTasks {
            guard case .create(let payload, _) = ops[index].kind,
                  payload.projectId == first.projectId else { break }
            run.append(ops[index])
            index += 1
        }
        return run
    }

    private func performBulkCreate(_ run: [PendingOp]) async throws {
        let payloads: [CreatePayload] = run.compactMap {
            if case .create(let payload, _) = $0.kind { return payload } else { return nil }
        }
        guard let projectId = payloads.first?.projectId else { return }
        let created = try await VikunjaAPI.createTasksBulk(
            projectId: projectId,
            tasks: payloads.map {
                VikunjaAPI.NewTask(title: $0.title, description: $0.description, dueDate: $0.dueDate,
                                   priority: $0.priority, reminders: $0.reminders,
                                   repeatAfter: $0.repeatAfter, repeatMode: $0.repeatMode)
            }
        )

        // A 201 means every task landed (the endpoint is atomic), so every op
        // comes off the queue even if the response were somehow shorter than
        // the request — leaving one behind would create that task a second time
        // on the next drain. Anything that couldn't be remapped is reconciled by
        // the refresh at the end of the drain.
        for (offset, op) in run.enumerated() {
            if offset < created.count, case .client(let uuid) = op.ref {
                outbox.remap(client: uuid, toServer: created[offset].id)
            }
            outbox.remove(id: op.id)
        }
        DiagnosticLog.info("op bulk create ×\(run.count) → \(created.count) ok")

        await attachLabels(payloads: payloads, created: created)
    }

    /// Labels still can't be set at create time (2.5.0 keeps them read-only on
    /// the create body), so they go on afterwards — one request per task via
    /// the bulk label-replace endpoint, four in flight at a time.
    ///
    /// A failure here must never fail the create: the tasks already exist and
    /// their ops are gone, so throwing would re-create them on the next drain.
    /// The labels are re-queued as an ordinary `.update` op instead and the
    /// outbox's existing retry machinery finishes the job.
    private func attachLabels(payloads: [CreatePayload], created: [VikunjaTask]) async {
        let pairs = Array(zip(payloads, created)).filter { !$0.0.labels.isEmpty }
        guard !pairs.isEmpty else { return }

        for start in stride(from: 0, to: pairs.count, by: 4) {
            let batch = pairs[start..<min(start + 4, pairs.count)]
            let failures = await withTaskGroup(of: (Int, [Int])?.self) { group -> [(Int, [Int])] in
                for (payload, task) in batch {
                    let labelIds = payload.labels.map(\.id)
                    let taskId = task.id
                    group.addTask {
                        do {
                            try await VikunjaAPI.setLabels(taskId: taskId, labelIds: labelIds)
                            return nil
                        } catch {
                            return (taskId, labelIds)
                        }
                    }
                }
                var collected: [(Int, [Int])] = []
                for await failure in group {
                    if let failure { collected.append(failure) }
                }
                return collected
            }

            for (taskId, labelIds) in failures {
                DiagnosticLog.warn("bulk create: labels for task \(taskId) deferred to outbox")
                outbox.append(PendingOp(
                    id: UUID(),
                    timestamp: Date(),
                    ref: .server(taskId),
                    kind: .update(update: TaskUpdate(labelIds: labelIds))
                ))
            }
        }
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
                await self?.refreshIfStale(background: true, reason: "poll")
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
