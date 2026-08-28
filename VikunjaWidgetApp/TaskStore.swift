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

    /// A reassuring, non-blocking heads-up — nothing failed. Presented as its
    /// own gently-titled alert, separate from `error`, and only set when
    /// `error` is clear so the two can't fight over the screen. Currently the
    /// one user: an import that fell back off the bulk endpoint because the
    /// API token predates it.
    var advisory: String?

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

    /// Per-account expansion state for the nested project lists. Replaced on
    /// account switch alongside `outbox` (see `resetPerAccountState`).
    private(set) var projectExpansion: ProjectExpansion

    let reachability = Reachability.shared

    /// Last server-fetched undone tasks before merger is applied.
    private var lastServerUndone: [VikunjaTask] = []

    // MARK: - Init

    init() {
        let accountId = VikunjaConfig.activeAccount?.id
        outbox = Outbox(accountId: accountId)
        projectExpansion = ProjectExpansion(accountId: accountId)
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

    /// The projects listed under the "Projects" heading — everything except
    /// the Inbox, which has its own row. Sidebar, iPhone root list and the
    /// launch-page picker all show this same list.
    var visibleProjects: [VikunjaProject] {
        projects
            .filter { $0.title.lowercased() != "inbox" }
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
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

    // MARK: - Project tree

    /// One row in a rendered project list: a project plus how deep to indent
    /// it. `depth` is the true tree depth — render sites cap the *visual*
    /// indent, not this.
    struct ProjectTreeRow: Identifiable {
        let project: VikunjaProject
        let depth: Int
        let hasChildren: Bool
        let expanded: Bool
        var id: Int { project.id }
    }

    /// Latches once per account so a malformed hierarchy logs a single line
    /// rather than one per view render. Not observed — it's toggled from
    /// `projectTree`, which runs during view evaluation.
    @ObservationIgnored private var loggedProjectCycle = false

    /// `visibleProjects` (already Inbox-less and title-sorted) split into its
    /// roots and a parent-id → children map. A project whose `parentId` names
    /// something **not** in `visibleProjects` is a root: a child of the Inbox,
    /// of a project the token can't read, or of one deleted server-side but
    /// still in a stale cache would otherwise hang off a parent that never
    /// renders and vanish from the list entirely. Siblings keep
    /// `visibleProjects`' order.
    private func projectHierarchy() -> (roots: [VikunjaProject], children: [Int: [VikunjaProject]]) {
        let visible = visibleProjects
        let ids = Set(visible.map(\.id))
        var children: [Int: [VikunjaProject]] = [:]
        var roots: [VikunjaProject] = []
        for project in visible {
            if let parent = project.parentId, ids.contains(parent) {
                children[parent, default: []].append(project)
            } else {
                roots.append(project)
            }
        }
        return (roots, children)
    }

    /// The visible projects as a depth-first flattened list — each project
    /// immediately followed by its children, descending into a project only
    /// when `expanded` contains its id.
    ///
    /// Two failure modes with hand-edited data are handled so a project can
    /// never disappear or hang the app: a chain that loops back on itself
    /// (A → B → A) is cut by the ancestor set carried down the walk, and a
    /// pure cycle with no external root — whose members no walk ever reaches —
    /// is swept up at the end and shown flat at the top level.
    func projectTree(expanded: Set<Int>) -> [ProjectTreeRow] {
        let (roots, children) = projectHierarchy()
        var rows: [ProjectTreeRow] = []
        var emitted: Set<Int> = []

        func emit(_ project: VikunjaProject, depth: Int, ancestors: Set<Int>) {
            if ancestors.contains(project.id) {
                if !loggedProjectCycle {
                    // ids only, never titles — DiagnosticLog privacy contract.
                    DiagnosticLog.warn("project tree: cycle at depth \(depth)")
                    loggedProjectCycle = true
                }
                return
            }
            emitted.insert(project.id)
            let kids = children[project.id] ?? []
            let isExpanded = expanded.contains(project.id)
            rows.append(ProjectTreeRow(
                project: project,
                depth: depth,
                hasChildren: !kids.isEmpty,
                expanded: isExpanded
            ))
            guard isExpanded else { return }
            let deeper = ancestors.union([project.id])
            for kid in kids {
                emit(kid, depth: depth + 1, ancestors: deeper)
            }
        }

        for root in roots {
            emit(root, depth: 0, ancestors: [])
        }

        // A pure cycle (or a self-parent) has no root, so nothing above ever
        // reached its members. Show them flat rather than let them vanish.
        for project in visibleProjects where !emitted.contains(project.id) {
            if !loggedProjectCycle {
                DiagnosticLog.warn("project tree: unrooted project hoisted to top level")
                loggedProjectCycle = true
            }
            rows.append(ProjectTreeRow(
                project: project,
                depth: 0,
                hasChildren: false,
                expanded: false
            ))
        }
        return rows
    }

    /// A project's own undone tasks plus every descendant's — the badge a
    /// **collapsed** parent shows, so collapsing never makes a count silently
    /// vanish. Same ancestor-set cycle guard as `projectTree`. `tasks(for:)`
    /// stays the exact-match "own tasks" query that `ProjectView` uses.
    func rolledUpTaskCount(for project: VikunjaProject) -> Int {
        let (_, children) = projectHierarchy()
        var total = 0
        var visited: Set<Int> = []
        func walk(_ project: VikunjaProject) {
            guard visited.insert(project.id).inserted else { return }
            total += tasks(for: project).count
            for kid in children[project.id] ?? [] { walk(kid) }
        }
        walk(project)
        return total
    }

    /// How many projects sit under `project` in the tree. Vikunja deletes
    /// sub-projects along with their parent, so the delete-confirmation copy
    /// uses this to say so. Cycle-guarded like the walks above.
    func descendantProjectCount(for project: VikunjaProject) -> Int {
        let (_, children) = projectHierarchy()
        var count = 0
        var visited: Set<Int> = []
        func walk(_ id: Int) {
            for kid in children[id] ?? [] where visited.insert(kid.id).inserted {
                count += 1
                walk(kid.id)
            }
        }
        walk(project.id)
        return count
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
        advisory = nil
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
        projectExpansion = ProjectExpansion(accountId: accountId)
        loggedProjectCycle = false
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

    /// Read by the Pending Changes sheet to disable its buttons while a drain
    /// is walking the queue — see `discard(opId:)` for why mutating underneath
    /// a running drain is unsafe.
    private(set) var isDraining = false

    /// Message for the write failure most recently alerted from a drain, so a
    /// queued op that keeps failing alerts once instead of on every poll.
    /// Cleared by the first drain that gets anything through — which is also
    /// the moment the user has fixed whatever it was. Also surfaced verbatim
    /// as the Pending Changes sheet's "why it's stuck" header.
    private(set) var lastDrainFailureMessage: String?

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
        // Set when a write fails for a reason the *user* has to clear — an
        // under-scoped or revoked token. Reported after the trailing refresh,
        // not here; see below.
        var blockingFailure: Error?
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
        // Set when the bulk endpoint 401s but the per-task fallback then
        // works — the signature of an API token minted before the server
        // gained the bulk-create permission (Vikunja 2.5.0). Used only to
        // show a one-time, reassuring "make a fresh token" note after the
        // drain; the import itself has already gone through.
        var staleTokenSuspected = false
        while index < snapshot.count {
            let op = snapshot[index]

            if !bulkDisabled, VikunjaAPI.supportsBulkTaskCreate,
               let run = bulkCreateRun(in: snapshot, from: index), run.count >= 2 {
                do {
                    try await performBulkCreate(run)
                    okCount += run.count
                    index += run.count
                    continue
                } catch let error as VikunjaAPI.APIError where error.isRateLimited {
                    // "Slow down" applies to every op behind this one too —
                    // stop here and let the next drain pick it up. Bulk create
                    // is atomic: nothing was created, the run stays queued.
                    DiagnosticLog.warn("drain paused: bulk create ×\(run.count) → 429 (ops kept)")
                    blockingFailure = error
                    break
                } catch let error as VikunjaAPI.APIError where error.isAuthFailure {
                    // A 401/403 from the *bulk* endpoint alone doesn't mean the
                    // token is bad: an API token created before the server
                    // gained the bulk-create permission (Vikunja 2.5.0) reads
                    // and single-creates fine but can't call this route. Fall
                    // back to per-task creates rather than blocking — if those
                    // also 401, the per-op handler below raises the real auth
                    // alert. Bulk create is atomic, so nothing was created and
                    // the fallback can't duplicate.
                    DiagnosticLog.warn("bulk create ×\(run.count) → \(error.statusCode), falling back to per-task creates (token may predate bulk support)")
                    bulkDisabled = true
                    staleTokenSuspected = true
                } catch let error as VikunjaAPI.APIError where error.isClient4xx {
                    // Bulk create is atomic — a 4xx means *nothing* was created,
                    // so replaying these as single creates can't duplicate
                    // anything. Falling back also isolates the bad task: the
                    // per-op path drops whichever one the server refuses on its
                    // merits, so it can't wedge the queue behind it.
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
            } catch let error as VikunjaAPI.APIError where error.isAuthFailure || error.isRateLimited {
                // Nothing is wrong with the edit — the credential is. Keeping
                // the op means it lands by itself once the token is fixed;
                // dropping it (which every 4xx used to do) threw the user's
                // change away and, because the editor had already closed
                // saying "saved", looked exactly like a successful save until
                // the next refresh snapped the task back.
                //
                // Stop the drain rather than working down the queue: every
                // remaining op carries the same credential and would fail the
                // same way, and one alert beats one per queued op.
                DiagnosticLog.warn("drain paused: \(opLabel(op)) → \(error.statusCode) (op kept)")
                blockingFailure = error
                break
            } catch let error as VikunjaAPI.APIError where error.isGone {
                // Task deleted server-side — the edit has nothing left to
                // apply to, so drop it.
                DiagnosticLog.warn("op \(opLabel(op)) → dropped (\(error.statusCode), task gone)")
                outbox.remove(id: op.id)
                droppedCount += 1
            } catch let error as VikunjaAPI.APIError where error.isClient4xx {
                // Malformed or otherwise refused on its merits (400, 422 …).
                // Replaying can only fail identically, so drop it rather than
                // wedging every later op behind it — but say so, because
                // unlike the two cases above this one means we built a bad
                // request and the log is the only place that shows up.
                DiagnosticLog.warn("op \(opLabel(op)) → dropped (\(error.statusCode), rejected)")
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

        // Deliberately after the refresh. `performRefresh` clears `error` on
        // entry, and for the case this exists to catch — a token that reads
        // fine and can't write — that refresh *succeeds*, so an alert raised
        // before it would be wiped by the very next line and the user would
        // once again be told nothing.
        //
        // The message guard is what keeps this to one alert: the op stays
        // queued now, so every later drain retries it and fails again, and
        // without the guard a permanently-under-scoped token would alert on
        // every 60s poll.
        if let blockingFailure {
            let message = VeyrnError.message(for: blockingFailure)
            if message != lastDrainFailureMessage {
                lastDrainFailureMessage = message
                report(blockingFailure)
            }
        } else if okCount > 0 {
            lastDrainFailureMessage = nil
        }

        // The bulk endpoint refused this token but the per-task fallback got
        // every task through — an old token missing the 2.5.0 bulk-create
        // permission. Nothing is broken, so this is a one-time heads-up, not
        // an error, and only when the fallback actually succeeded.
        if staleTokenSuspected, okCount > 0, blockingFailure == nil {
            adviseStaleTokenOnce()
        }
    }

    /// One-time, reassuring note shown after a bulk import went through on the
    /// per-task fallback because the API token predates the server's
    /// bulk-create permission (Vikunja 2.5.0). Not an error — everything
    /// imported — so it uses the separate `advisory` channel, and a persisted
    /// flag keeps it to a single appearance ever.
    private func adviseStaleTokenOnce() {
        let key = "veyrn.advisory.bulkTokenStale.shown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        DiagnosticLog.info("advisory: bulk create fell back to per-task (token predates 2.5.0 bulk permission)")
        // Don't burn the one-shot if an error alert is already on screen —
        // try again next time rather than losing the note.
        guard error == nil else { return }
        UserDefaults.standard.set(true, forKey: key)
        advisory = """
        All your tasks were imported. One note: this API token was created \
        before your Vikunja server could create tasks in batches, so Veyrn \
        added them one at a time. Everything works as-is — but if you make a \
        fresh API token in Vikunja (Settings → API Tokens) and paste it into \
        Veyrn's Settings, large imports will be faster.
        """
    }

    // MARK: - Pending Changes sheet

    /// The queued outbox ops as display rows, in queue order. `TaskStore`
    /// builds these because it is the only place that can resolve a `TaskRef`
    /// to a task title.
    var pendingChanges: [PendingChange] {
        outbox.ops.map { op in
            switch op.kind {
            case .create(let payload, _):
                return PendingChange(
                    id: op.id,
                    icon: "plus.circle",
                    kindLabel: String(localized: "New task", comment: "Pending Changes row: a queued task creation"),
                    taskTitle: payload.title,
                    queuedAt: op.timestamp,
                    // A queued create exists nowhere but this queue, so
                    // discarding it deletes the task outright.
                    deletesTask: true
                )
            case .update:
                return PendingChange(
                    id: op.id, icon: "pencil",
                    kindLabel: String(localized: "Edit", comment: "Pending Changes row: a queued edit to a task"),
                    taskTitle: title(for: op.ref), queuedAt: op.timestamp, deletesTask: false
                )
            case .complete:
                return PendingChange(
                    id: op.id, icon: "checkmark.circle",
                    kindLabel: String(localized: "Completed", comment: "Pending Changes row: a queued task completion"),
                    taskTitle: title(for: op.ref), queuedAt: op.timestamp, deletesTask: false
                )
            case .reopen:
                return PendingChange(
                    id: op.id, icon: "arrow.uturn.backward",
                    kindLabel: String(localized: "Reopened", comment: "Pending Changes row: a queued task reopen"),
                    taskTitle: title(for: op.ref), queuedAt: op.timestamp, deletesTask: false
                )
            case .relation(let parentRef, _, _, _):
                return PendingChange(
                    id: op.id, icon: "link",
                    kindLabel: String(localized: "Subtask link", comment: "Pending Changes row: a queued subtask relation change"),
                    taskTitle: title(for: parentRef), queuedAt: op.timestamp, deletesTask: false
                )
            }
        }
    }

    /// Raw op counts for the "Discard All" confirmation: `creates` become task
    /// deletions, everything else is an undo.
    var pendingDiscardSummary: (creates: Int, others: Int) {
        var creates = 0
        var others = 0
        for op in outbox.ops {
            if case .create = op.kind { creates += 1 } else { others += 1 }
        }
        return (creates, others)
    }

    /// Human-readable title for a queued op's target task. Searches the live
    /// undone list, then the logbook, by the ref's resolved id. **A miss is
    /// expected** — a reopened task is briefly in neither list, and a
    /// `.complete`'s task can be mid-transition — so this falls back to a
    /// neutral label and never surfaces a negative placeholder id.
    private func title(for ref: TaskRef) -> String {
        switch ref {
        case .server(let id):
            if let task = undoneTasks.first(where: { $0.id == id })
                ?? doneTasks.first(where: { $0.id == id }) {
                return task.title
            }
            return String(localized: "Task #\(id)", comment: "Pending Changes row fallback when the task isn't in the loaded lists")
        case .client(let uuid):
            if let placeholderId = outbox.placeholderId(forClient: uuid),
               let task = undoneTasks.first(where: { $0.id == placeholderId })
                ?? doneTasks.first(where: { $0.id == placeholderId }) {
                return task.title
            }
            // The merged row isn't there — fall back to the queued create's
            // own title before giving up. Never show the placeholder id.
            for op in outbox.ops {
                if case .client(let opUUID) = op.ref, opUUID == uuid,
                   case .create(let payload, _) = op.kind {
                    return payload.title
                }
            }
            return String(localized: "New task", comment: "Pending Changes row: a queued task creation")
        }
    }

    /// Resolves a ref to the id its task carries in the *local* merged lists —
    /// a real server id, or the negative placeholder id for an offline create.
    private func localId(for ref: TaskRef) -> Int? {
        switch ref {
        case .server(let id): return id
        case .client(let uuid): return outbox.placeholderId(forClient: uuid)
        }
    }

    /// Removes a single queued change — and, for a queued offline `.create`,
    /// every later op that depends on it — then undoes whatever local side
    /// effect enqueuing those ops performed. Called only from the Pending
    /// Changes sheet.
    @MainActor
    func discard(opId: UUID) async {
        guard let op = outbox.ops.first(where: { $0.id == opId }) else { return }
        // The drain walks a snapshot and removes ops as they land; mutating the
        // queue underneath it risks cancelling a change already on the wire.
        // The sheet also disables its buttons while `isDraining`, but a poll
        // can start one between the tap and here.
        guard !isDraining else {
            DiagnosticLog.info("discard ignored — drain in progress")
            return
        }

        // Cascade: discarding an offline create must also discard every op that
        // targets the same not-yet-created task. `drainOutbox` skips any op
        // whose `.client` ref can't resolve to a server id (`serverId(for:)
        // == nil` → `continue`), so a stranded `.update`/`.complete`/
        // `.relation` would sit in the queue forever — never sent, never
        // failed, never removed — leaving a permanent "N pending" that no
        // retry and no discard could clear.
        var doomed: Set<UUID> = [op.id]
        if case .create = op.kind, case .client(let uuid) = op.ref {
            for other in outbox.ops where other.id != op.id {
                if case .client(let otherUUID) = other.ref, otherUUID == uuid {
                    doomed.insert(other.id)
                    continue
                }
                if case .relation(let parentRef, let childRef, _, _) = other.kind {
                    if case .client(let u) = parentRef, u == uuid { doomed.insert(other.id) }
                    if case .client(let u) = childRef, u == uuid { doomed.insert(other.id) }
                }
            }
        }

        let discarded = outbox.ops.filter { doomed.contains($0.id) }
        await applyDiscard(of: discarded, logHead: "discard op \(opLabel(op))", cascadeExtra: doomed.count - 1)
    }

    /// Removes every queued change at once, undoing each one's local side
    /// effect — the "Discard All" path.
    @MainActor
    func discardAll() async {
        guard !isDraining else {
            DiagnosticLog.info("discardAll ignored — drain in progress")
            return
        }
        guard !outbox.ops.isEmpty else { return }
        let summary = pendingDiscardSummary
        await applyDiscard(
            of: outbox.ops,
            logHead: "discard all: \(summary.creates) create, \(summary.others) other",
            cascadeExtra: 0
        )
    }

    /// Shared body of `discard`/`discardAll`: undo the per-kind local side
    /// effects, drop the ops, rebuild, and re-arm anything the enqueue tore
    /// down. Everything up to the trailing `await`s runs synchronously on the
    /// main actor, so a concurrent drain can't observe a half-updated queue;
    /// by the time those awaits suspend, the queue is already settled.
    @MainActor
    private func applyDiscard(of discarded: [PendingOp], logHead: String, cascadeExtra: Int) async {
        let hadComplete = discarded.contains { if case .complete = $0.kind { return true } else { return false } }
        let hadReopen = discarded.contains { if case .reopen = $0.kind { return true } else { return false } }

        for op in discarded {
            switch op.kind {
            case .complete:
                // `commitCompletion` moved the task into `doneTasks` and
                // cancelled its reminders. Take it back out here;
                // `rebuildMergedTasks()` re-derives it into `undoneTasks` from
                // the untouched server list, and the reminder is re-armed below.
                if let id = localId(for: op.ref) {
                    doneTasks.removeAll { $0.id == id }
                }
            case .reopen:
                // `reopen` removed the task from `doneTasks` and kept no local
                // copy. `refreshLogbook()` at the tail rebuilds `doneTasks`
                // from the server (which still reports it done) now the op is
                // gone; offline, it returns on the next Logbook sync.
                break
            case .create, .update, .relation:
                // No explicit undo — `rebuildMergedTasks()` re-derives the
                // correct state from `lastServerUndone` once the op is gone.
                break
            }
        }

        if discarded.count == outbox.ops.count {
            outbox.removeAll()          // one write instead of one per op
        } else {
            for op in discarded { outbox.remove(id: op.id) }
        }
        if hadComplete { saveDoneCache() }
        rebuildMergedTasks()

        // The blocking condition no longer has anything to block.
        if outbox.ops.isEmpty { lastDrainFailureMessage = nil }
        WidgetCenter.shared.reloadAllTimelines()
        DiagnosticLog.info("\(logHead)\(cascadeExtra > 0 ? " (+\(cascadeExtra) dependent)" : "")")

        if hadComplete {
            await ReminderScheduler.sync(tasks: undoneTasks)
        }
        if hadReopen {
            await refreshLogbook()
        }
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
