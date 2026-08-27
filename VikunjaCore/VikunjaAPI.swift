import Foundation

enum VikunjaAPI {
    private static var baseURL: String { VikunjaConfig.baseURL }

    /// Own session rather than `URLSession.shared` so `waitsForConnectivity`
    /// can be set: a cold radio then waits for a route instead of failing
    /// instantly with "The request timed out." The widget extension stays
    /// bounded regardless — `VikunjaTimelineProvider` races its fetch against
    /// its own 10s `withTimeout`.
    ///
    /// `timeoutIntervalForResource` was 45 s and is now **25 s**. With
    /// `waitsForConnectivity` the request timeout doesn't start until a
    /// connection exists, so the resource ceiling is what a stalled request
    /// actually costs — and on macOS ~35% of refreshes were burning the full
    /// 45 s (see the open timeout issue). 25 s halves the staleness window and
    /// stops one stuck request from blocking later refreshes for that long,
    /// while keeping real headroom over the 20 s request timeout for a cold
    /// radio or a VPN still coming up, which is what the 2.7.4 fix needed.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    /// Whether a failed v2 request should be re-thrown instead of retried on
    /// v1. The fallback exists for servers that don't speak v2 — it can't help
    /// with failures that aren't about the API version, and the second request
    /// fails the same way a moment later.
    ///
    /// - Cancellation is our own doing (quitting, switching accounts); a
    ///   second full fetch would paper over it.
    /// - A gateway error (502/503/504) came from a proxy or CDN that couldn't
    ///   reach Vikunja. The request never arrived, so it says nothing at all
    ///   about v2 support.
    /// - A connectivity failure — overwhelmingly a request the machine slept
    ///   through — likewise never reached a server that could have had an
    ///   opinion about v2. Retrying it on v1 is actively harmful: it drops the
    ///   refresh onto the per-project fan-out, 17–18 requests where v2 needs 4,
    ///   which is the path with the whole stall history. Build 74's overnight
    ///   log downgraded 21 times this way, and the fan-out then got caught by
    ///   the *next* sleep, turning one dead request into a failed refresh.
    private static func v1FallbackIsPointless(_ error: Error) -> Bool {
        VeyrnError.isCancellation(error)
            || VeyrnError.isGatewayFailure(error)
            || VeyrnError.isConnectivityOnly(error)
    }

    // MARK: - Projects

    static func createProject(title: String) async throws -> VikunjaProject {
        let body = try JSONSerialization.data(withJSONObject: ["title": title])
        if supportsAPIv2 {
            return try await postV2("/projects", body: body, as: VikunjaProject.self)
        }
        return try await put("/projects", body: body, as: VikunjaProject.self)
    }

    static func deleteProject(id: Int) async throws {
        if supportsAPIv2 {
            try await deleteV2("/projects/\(id)")
            return
        }
        let request = makeRequest("/projects/\(id)", method: "DELETE")
        _ = try await send(request)
    }

    static func fetchAllProjects() async throws -> [VikunjaProject] {
        if supportsAPIv2 {
            do {
                return try await getV2Paged("/projects", perPage: 100)
            } catch {
                if v1FallbackIsPointless(error) { throw error }
                DiagnosticLog.warn("v2 fetchAllProjects failed (\(VeyrnError.logDescription(for: error))) — falling back to v1")
            }
        }
        var all: [VikunjaProject] = []
        var page = 1
        while true {
            let batch = try await get("/projects?per_page=100&page=\(page)", as: [VikunjaProject].self)
            all.append(contentsOf: batch)
            if batch.count < 100 { break }
            page += 1
        }
        return all
    }

    // MARK: - Tasks (undone)

    static func fetchAllUndoneTasks(projects: [VikunjaProject]? = nil) async throws -> [VikunjaTask] {
        let projectList: [VikunjaProject]
        if let projects {
            projectList = projects
        } else {
            projectList = try await fetchAllProjects()
        }

        // v2 replaces the whole per-project fan-out with one paged endpoint.
        // That matters beyond tidiness: the fan-out is what triggers the
        // macOS stall — requests that never get a connection slot at all
        // (`no connection attempt`), 1–2 per refresh, killing the whole
        // refresh. One request can't contend with itself.
        if supportsAPIv2 {
            do {
                let tasks = try await fetchAllUndoneTasksV2(
                    knownProjectIds: Set(projectList.map(\.id))
                )
                DiagnosticLog.info("fetch path: v2, \(tasks.count) undone")
                return tasks
            } catch {
                if v1FallbackIsPointless(error) { throw error }
                DiagnosticLog.warn("v2 task fetch failed (\(VeyrnError.logDescription(for: error))) — falling back to v1 fan-out")
            }
        }

        return try await fetchTasksAcrossProjects(projectList.map(\.id), done: false)
    }

    /// Bounded fan-out: at most `maxConcurrentProjectFetches` in flight rather
    /// than one per project. Twelve simultaneous requests is what leaves one
    /// or two queued behind connection slots they never get; four keeps the
    /// client's own scheduler out of the picture. Used for v1 servers and as
    /// the v2 fallback.
    private static let maxConcurrentProjectFetches = 4

    private static func fetchTasksAcrossProjects(_ projectIds: [Int], done: Bool, page: Int = 1) async throws -> [VikunjaTask] {
        var combined: [VikunjaTask] = []
        var next = 0
        try await withThrowingTaskGroup(of: [VikunjaTask].self) { group in
            func addNext() {
                guard next < projectIds.count else { return }
                let projectId = projectIds[next]
                next += 1
                group.addTask { try await fetchTasksRetrying(projectId: projectId, done: done, page: page) }
            }
            for _ in 0..<min(maxConcurrentProjectFetches, projectIds.count) { addNext() }
            while let batch = try await group.next() {
                combined.append(contentsOf: batch)
                addNext()
            }
        }
        return combined
    }

    /// One retry for a single project before the whole refresh is written off.
    /// The task group cancels every sibling on the first throw, so one stalled
    /// request was discarding eleven successful ones — 46% of refreshes failed
    /// this way on macOS. Still all-or-nothing overall: a partial result would
    /// silently make a project's tasks vanish from the lists.
    private static func fetchTasksRetrying(projectId: Int, done: Bool, page: Int) async throws -> [VikunjaTask] {
        do {
            return try await fetchTasks(projectId: projectId, done: done, page: page)
        } catch {
            // Never retry a cancellation — that's the group tearing down.
            guard !VeyrnError.isCancellation(error),
                  VeyrnError.isConnectivityOnly(error) || VeyrnError.isRetryable(error)
            else { throw error }
            DiagnosticLog.warn("project \(projectId) fetch failed (\(VeyrnError.logDescription(for: error))) — retrying once")
            return try await fetchTasks(projectId: projectId, done: done, page: page)
        }
    }

    // MARK: - Tasks (done / logbook)

    static func fetchDoneTasks(page: Int = 1) async throws -> [VikunjaTask] {
        // v2 replaces the per-project-fan-out-then-merge with one request: the
        // server's own "50 most recently completed overall" is a strictly
        // better page 1 than v1's "50 done per project". Deliberately does not
        // follow total_pages here — `page` is the logbook's own paging, not a
        // full-drain loop.
        if supportsAPIv2 {
            do {
                let path = "/tasks?filter=done+%3D+true&sort_by=done_at&order_by=desc&per_page=50&page=\(page)"
                let result: V2Page<VikunjaTask> = try await getV2(path, as: V2Page<VikunjaTask>.self)
                let tasks = result.items ?? []
                return tasks.sorted { ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast) }
            } catch {
                if v1FallbackIsPointless(error) { throw error }
                DiagnosticLog.warn("v2 fetchDoneTasks failed (\(VeyrnError.logDescription(for: error))) — falling back to v1")
            }
        }
        let projectList = try await fetchAllProjects()
        let tasks = try await fetchTasksAcrossProjects(projectList.map(\.id), done: true, page: page)
        return tasks.sorted { ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast) }
    }

    // MARK: - Single task (includes related_tasks from the server)

    /// Public routed fetch — v2 when available (bare object, `related_tasks`
    /// included with no `expand` needed), v1 fallback on any failure. Internal
    /// callers that pre-fetch as part of a v1 read-modify-write mutation
    /// (`setDone`, the v1 branch of `updateTask`) use `fetchTaskV1` directly so
    /// a v1 mutation never mixes a v2 read with a v1 write.
    static func fetchTask(id: Int) async throws -> VikunjaTask {
        if supportsAPIv2 {
            do {
                return try await getV2("/tasks/\(id)", as: VikunjaTask.self)
            } catch {
                if v1FallbackIsPointless(error) { throw error }
                DiagnosticLog.warn("v2 fetchTask failed (\(VeyrnError.logDescription(for: error))) — falling back to v1")
            }
        }
        return try await fetchTaskV1(id: id)
    }

    private static func fetchTaskV1(id: Int) async throws -> VikunjaTask {
        return try await get("/tasks/\(id)", as: VikunjaTask.self)
    }

    // MARK: - Server info

    /// Fetches server metadata. Unauthenticated on the server side, but goes
    /// through the normal request path (the bearer header is harmless here).
    static func fetchServerInfo() async throws -> VikunjaServerInfo {
        try await get("/info", as: VikunjaServerInfo.self)
    }

    // MARK: - Mutations

    static func deleteTask(id: Int) async throws {
        if supportsAPIv2 {
            try await deleteV2("/tasks/\(id)")
            return
        }
        let request = makeRequest("/tasks/\(id)", method: "DELETE")
        _ = try await send(request)
    }

    /// v2: a single merge-patch `{"done": true/false}` — confirmed server-side
    /// that a repeating task still reschedules (server keeps `done:false` and
    /// advances `due_date`), identical to v1's full-POST behavior. No v1
    /// fallback on failure (ground rule: mutations route by flag, never retry
    /// on v1 — the flag is only true after the server itself reported ≥2.4.0).
    static func completeTask(id: Int) async throws {
        if supportsAPIv2 {
            try await patchV2("/tasks/\(id)", body: ["done": true])
            return
        }
        try await setDone(id: id, done: true)
    }

    static func reopenTask(id: Int) async throws {
        if supportsAPIv2 {
            try await patchV2("/tasks/\(id)", body: ["done": false])
            return
        }
        try await setDone(id: id, done: false)
    }

    /// v1 only. Toggle done state while preserving every other field. Vikunja's
    /// Go server treats fields omitted from the JSON body as zero-valued (e.g.
    /// `due_date` becomes `0001-01-01`), which silently wipes the due date. The
    /// web client avoids this by sending the full task object — we mirror that
    /// here by fetching the current task and re-posting it with `done`
    /// overridden. Uses `fetchTaskV1`, not the routed `fetchTask`, so this v1
    /// mutation never reads via v2.
    private static func setDone(id: Int, done: Bool) async throws {
        var task = try await fetchTaskV1(id: id)
        task.done = done
        let body = try JSONEncoder().encode(task)
        let request = makeRequest("/tasks/\(id)", method: "POST", body: body)
        _ = try await send(request)
    }

    static func createTask(
        projectId: Int,
        title: String,
        description: String? = nil,
        dueDate: Date? = nil,
        priority: Int? = nil,
        labelIds: [Int] = [],
        reminders: [Date] = [],
        repeatAfter: Int? = nil,
        repeatMode: Int? = nil
    ) async throws -> VikunjaTask {
        let body = taskCreateBody(
            title: title, description: description, dueDate: dueDate, priority: priority,
            reminders: reminders, repeatAfter: repeatAfter, repeatMode: repeatMode
        )
        let data = try JSONSerialization.data(withJSONObject: body)
        // Create stays under the project on v2 too — there is no flat
        // `POST /tasks` (405). Same body dictionary as the v1 path.
        let task: VikunjaTask
        if supportsAPIv2 {
            task = try await postV2("/projects/\(projectId)/tasks", body: data, as: VikunjaTask.self)
        } else {
            task = try await put("/projects/\(projectId)/tasks", body: data, as: VikunjaTask.self)
        }

        // Vikunja ignores labels on task creation — assign each via dedicated endpoint
        if !labelIds.isEmpty {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for labelId in labelIds {
                    group.addTask { try await addLabelToTask(taskId: task.id, labelId: labelId) }
                }
                try await group.waitForAll()
            }
        }

        // Re-fetch so the returned task includes the newly assigned labels.
        // Vikunja's create/label responses don't embed the full label objects.
        return try await fetchTask(id: task.id)
    }

    /// The create body, shared by the single-task path and every entry of a v2
    /// bulk create (2.5.0+ accepts exactly the same fields per entry). Kept in
    /// one place so the two can't drift — e.g. the local-8-PM snap that
    /// `applyDefaultTime` does to a bare due date.
    private static func taskCreateBody(
        title: String,
        description: String?,
        dueDate: Date?,
        priority: Int?,
        reminders: [Date],
        repeatAfter: Int?,
        repeatMode: Int?
    ) -> [String: Any] {
        var body: [String: Any] = ["title": title]
        if let description, !description.isEmpty { body["description"] = description }
        if let dueDate {
            body["due_date"] = ISO8601DateFormatter().string(from: applyDefaultTime(dueDate))
        }
        if let priority { body["priority"] = priority }
        if !reminders.isEmpty {
            body["reminders"] = reminders.map { ["reminder": ISO8601DateFormatter().string(from: $0)] }
        }
        if let repeatAfter, repeatAfter > 0 {
            body["repeat_after"] = repeatAfter
            body["repeat_mode"] = repeatMode ?? 0
        }
        return body
    }

    // MARK: - Bulk task creation (Vikunja 2.5.0+, v2 only)

    /// One task in a bulk-create request. `Outbox`'s `CreatePayload` would be
    /// the natural argument type, but `Outbox.swift` isn't in the Watch
    /// targets' `VikunjaCore` include lists and `VikunjaAPI.swift` is, so the
    /// API layer takes its own small value type and `TaskStore` maps into it.
    struct NewTask {
        let title: String
        let description: String?
        let dueDate: Date?
        let priority: Int?
        let reminders: [Date]
        let repeatAfter: Int?
        let repeatMode: Int?

        init(title: String, description: String? = nil, dueDate: Date? = nil,
             priority: Int? = nil, reminders: [Date] = [],
             repeatAfter: Int? = nil, repeatMode: Int? = nil) {
            self.title = title
            self.description = description
            self.dueDate = dueDate
            self.priority = priority
            self.reminders = reminders
            self.repeatAfter = repeatAfter
            self.repeatMode = repeatMode
        }
    }

    /// The server's hard cap on one bulk-create request (`maxItems: 100` in the
    /// 2.5.0 schema). Callers cap each batch at this, so a 250-task import
    /// becomes three accepted requests rather than one rejected one.
    static let bulkCreateMaxTasks = 100

    private struct BulkCreateResponse: Decodable { let tasks: [VikunjaTask]? }

    /// Creates up to `bulkCreateMaxTasks` tasks in one project in a single
    /// atomic request. Returns the created tasks **in payload order**, which is
    /// what the caller uses to remap placeholder ids.
    ///
    /// Atomicity is what lets this coexist with the "v2 mutations never
    /// auto-retry" invariant: the server documents that if any task is invalid
    /// none are created, so a non-2xx response means nothing landed and the
    /// caller may fall back to per-task creates without risking duplicates. A
    /// 201 means *all* of them landed.
    ///
    /// Labels are read-only at create time here too (same as the single-task
    /// endpoint) — attach them afterwards with `setLabels`.
    static func createTasksBulk(projectId: Int, tasks: [NewTask]) async throws -> [VikunjaTask] {
        guard supportsBulkTaskCreate else { throw V2NotAvailable() }
        let slice = Array(tasks.prefix(bulkCreateMaxTasks))
        guard !slice.isEmpty else { return [] }
        let entries = slice.map {
            taskCreateBody(title: $0.title, description: $0.description, dueDate: $0.dueDate,
                           priority: $0.priority, reminders: $0.reminders,
                           repeatAfter: $0.repeatAfter, repeatMode: $0.repeatMode)
        }
        let data = try JSONSerialization.data(withJSONObject: ["tasks": entries])
        let response = try await postV2("/projects/\(projectId)/tasks/bulk",
                                        body: data, as: BulkCreateResponse.self)
        return response.tasks ?? []
    }

    /// Replaces a task's entire label set in one request (2.5.0+). Used right
    /// after `createTasksBulk`, where the task is brand new and has no labels
    /// yet, so "replace" is simply "attach these" — one request instead of one
    /// per label.
    static func setLabels(taskId: Int, labelIds: [Int]) async throws {
        guard supportsBulkTaskCreate else { throw V2NotAvailable() }
        let body = try JSONSerialization.data(withJSONObject: ["labels": labelIds.map { ["id": $0] }])
        try await putV2("/tasks/\(taskId)/labels/bulk", body: body)
    }

    // MARK: - Labels

    /// Allowed characters for a *value* inside a query string. `.urlQueryAllowed`
    /// permits characters that are legal in a query as a whole but change its
    /// meaning inside a value — `&` starts a new parameter, `+` decodes as a
    /// space, `=`/`?`/`#` are structural — so a search for "R&D" or "a+b" was
    /// silently mangled into the wrong query.
    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()

    static func fetchLabels(search: String = "") async throws -> [VikunjaLabel] {
        let encoded = search.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? search
        if supportsAPIv2 {
            do {
                // v2 renamed the label search param s→q.
                let path = search.isEmpty ? "/labels" : "/labels?q=\(encoded)"
                return try await getV2Paged(path, perPage: 50)
            } catch {
                if v1FallbackIsPointless(error) { throw error }
                DiagnosticLog.warn("v2 fetchLabels failed (\(VeyrnError.logDescription(for: error))) — falling back to v1")
            }
        }
        var all: [VikunjaLabel] = []
        var page = 1
        while true {
            let path = search.isEmpty
                ? "/labels?per_page=50&page=\(page)"
                : "/labels?s=\(encoded)&per_page=50&page=\(page)"
            let batch = try await get(path, as: [VikunjaLabel].self)
            all += batch
            if batch.count < 50 { break }
            page += 1
        }
        return all
    }

    static func createLabel(title: String) async throws -> VikunjaLabel {
        let body = try JSONSerialization.data(withJSONObject: ["title": title])
        if supportsAPIv2 {
            return try await postV2("/labels", body: body, as: VikunjaLabel.self)
        }
        return try await put("/labels", body: body, as: VikunjaLabel.self)
    }

    /// v2 attach is a body-POST with the same shape as v1 (verb PUT→POST) —
    /// `POST /tasks/{id}/labels/{labelId}` (path-only form) is 405.
    static func addLabelToTask(taskId: Int, labelId: Int) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["label_id": labelId])
        if supportsAPIv2 {
            try await postV2("/tasks/\(taskId)/labels", body: body)
            return
        }
        let request = makeRequest("/tasks/\(taskId)/labels", method: "PUT", body: body)
        _ = try await send(request)
    }

    // MARK: - Task relations (subtasks)

    /// v2 add is a body-POST with the same shape as v1 (verb PUT→POST) — the
    /// path-only form is 405. Remove is identical to v1 on both flavors.
    static func addRelation(taskId: Int, otherTaskId: Int, kind: String = "subtask") async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "other_task_id": otherTaskId,
            "relation_kind": kind,
        ])
        if supportsAPIv2 {
            try await postV2("/tasks/\(taskId)/relations", body: body)
            return
        }
        let request = makeRequest("/tasks/\(taskId)/relations", method: "PUT", body: body)
        _ = try await send(request)
    }

    static func removeRelation(taskId: Int, otherTaskId: Int, kind: String = "subtask") async throws {
        let path = "/tasks/\(taskId)/relations/\(kind)/\(otherTaskId)"
        if supportsAPIv2 {
            try await deleteV2(path)
            return
        }
        let request = makeRequest(path, method: "DELETE")
        _ = try await send(request)
    }

    // MARK: - Date helpers

    /// Snaps a date to 8 PM local time, preserving the calendar day in local time.
    static func applyDefaultTime(_ date: Date) -> Date {
        let local = TimeZone.current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = local
        var comps = cal.dateComponents([.year, .month, .day], from: date)
        comps.hour = 20
        comps.minute = 0
        comps.second = 0
        comps.timeZone = local
        return cal.date(from: comps) ?? date
    }

    // MARK: - Task update

    /// The headline v2 win: merge-patch means only the changed fields are ever
    /// sent, so omitted fields structurally can't be clobbered — no pre-fetch
    /// needed for the patch itself (V-2). This eliminates the 2.7.1 bug class
    /// on v2 servers. A definitive 422 falls back to the existing v1 path;
    /// ambiguous transport failures still never replay a mutation.
    static func updateTask(id: Int, update: TaskUpdate) async throws -> VikunjaTask {
        if supportsAPIv2 {
            return try await performV2TaskUpdate(
                updateV2: { try await updateTaskV2(id: id, update: update) },
                fetchUpdated: { try await fetchTask(id: id) },
                updateV1: { try await updateTaskV1(id: id, update: update) }
            )
        }
        return try await updateTaskV1(id: id, update: update)
    }

    struct V2TaskPatchRejected: Error {}

    static func performV2TaskUpdate<T>(
        updateV2: () async throws -> Void,
        fetchUpdated: () async throws -> T,
        updateV1: () async throws -> T
    ) async throws -> T {
        do {
            try await updateV2()
        } catch {
            guard error is V2TaskPatchRejected else { throw error }
            DiagnosticLog.warn(
                "v2 task update returned 422; falling back to v1"
            )
            return try await updateV1()
        }
        return try await fetchUpdated()
    }

    /// Vikunja 2.4.0 can reject AutoPatch's internally merged task when a
    /// read-only response field does not match the PUT schema. A 422 proves
    /// the PATCH was rejected before mutation, so retrying the existing v1
    /// full-update path cannot double-apply the edit.
    static func v2TaskPatchIsUnprocessable(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        return apiError.statusCode == 422
    }

    private static func updateTaskV2(id: Int, update: TaskUpdate) async throws {
        let iso = ISO8601DateFormatter()
        var body: [String: Any] = [:]

        if let title = update.title { body["title"] = title }
        if let description = update.description { body["description"] = description }
        if let projectId = update.projectId { body["project_id"] = projectId }

        // Merge-patch needs an *explicit* null to clear a field and an
        // *absent* key for "no change" — JSONSerialization dictionaries can
        // express that distinction; Codable can't.
        if update.clearDueDate {
            body["due_date"] = NSNull()
        } else if let due = update.dueDate {
            body["due_date"] = iso.string(from: due)
        }

        if update.clearPriority {
            // 0 is Vikunja's "unset" sentinel for priority — not null (V-priority note).
            body["priority"] = 0
        } else if let priority = update.priority {
            body["priority"] = priority
        }

        if let reminders = update.reminders {
            // [] clears all reminders (merge-patch replaces arrays wholesale, V-12).
            body["reminders"] = reminders.map { ["reminder": iso.string(from: $0)] }
        }

        if update.clearRepeat {
            body["repeat_after"] = 0
            body["repeat_mode"] = 0
        } else if let repeatAfter = update.repeatAfter {
            body["repeat_after"] = repeatAfter
            body["repeat_mode"] = update.repeatMode ?? 0
        }

        if !body.isEmpty {
            do {
                try await patchV2("/tasks/\(id)", body: body)
            } catch {
                if v2TaskPatchIsUnprocessable(error) {
                    throw V2TaskPatchRejected()
                }
                throw error
            }
        }

        if let labelIds = update.labelIds {
            try await syncLabelsV2(taskId: id, desiredLabelIds: labelIds)
        }
    }

    /// Diffs current label ids against desired and attaches/detaches only the
    /// difference (V-10) — merge-patch has no array-diff semantics for labels,
    /// they're a separate sub-resource on both API flavors.
    private static func syncLabelsV2(taskId: Int, desiredLabelIds: [Int]) async throws {
        let current = try await getV2("/tasks/\(taskId)", as: VikunjaTask.self)
        let currentIds = Set((current.labels ?? []).map(\.id))
        let desiredIds = Set(desiredLabelIds)

        for labelId in desiredIds.subtracting(currentIds) {
            try await addLabelToTask(taskId: taskId, labelId: labelId)
        }
        for labelId in currentIds.subtracting(desiredIds) {
            try await deleteV2("/tasks/\(taskId)/labels/\(labelId)")
        }
    }

    /// v1 only: Vikunja's Go server treats every field omitted from the JSON
    /// body as zero-valued, so a partial update silently wipes unrelated
    /// fields — e.g. adding a reminder (body has `reminders` but no
    /// `due_date`) clears the due date, and adding a due date clears existing
    /// reminders. Mirror the web client / `setDone`: fetch the current task,
    /// overlay only the changed fields, and re-post the full object so
    /// nothing gets clobbered. Uses `fetchTaskV1` throughout so this v1
    /// mutation never mixes in a v2 read.
    private static func updateTaskV1(id: Int, update: TaskUpdate) async throws -> VikunjaTask {
        let iso = ISO8601DateFormatter()
        var task = try await fetchTaskV1(id: id)

        if let title = update.title { task.title = title }
        if let description = update.description { task.description = description }
        if let projectId = update.projectId { task.projectId = projectId }

        if update.clearDueDate {
            task.dueDate = "0001-01-01T00:00:00Z"
        } else if let due = update.dueDate {
            task.dueDate = iso.string(from: due)
        }

        if update.clearPriority {
            task.priority = 0
        } else if let priority = update.priority {
            task.priority = priority
        }

        if let reminders = update.reminders {
            task.reminders = reminders.map { VikunjaReminder(reminder: iso.string(from: $0)) }
        }

        if update.clearRepeat {
            task.repeatAfter = 0
            task.repeatMode = 0
        } else if let repeatAfter = update.repeatAfter {
            task.repeatAfter = repeatAfter
            task.repeatMode = update.repeatMode ?? 0
        }

        if let labelIds = update.labelIds {
            // Resolve against the labels already on the task; unknown ids fall back
            // to an id-only stub (Vikunja keys labels by id on update).
            var lookup: [Int: VikunjaLabel] = [:]
            for label in task.labels ?? [] { lookup[label.id] = label }
            task.labels = labelIds.map { lookup[$0] ?? VikunjaLabel(id: $0, title: "", hexColor: nil) }
        }

        let body = try JSONEncoder().encode(task)
        _ = try await post("/tasks/\(id)", body: body, as: VikunjaTask.self)
        // Re-fetch so the returned task includes updated labels.
        // Vikunja's POST /tasks/{id} response doesn't reliably embed label objects.
        return try await fetchTaskV1(id: id)
    }

    // MARK: - Private helpers

    private static func fetchTasks(projectId: Int, done: Bool, page: Int = 1) async throws -> [VikunjaTask] {
        let filter = done ? "done+%3D+true" : "done+%3D+false"
        var all: [VikunjaTask] = []
        var currentPage = page
        while true {
            let path = "/projects/\(projectId)/tasks?filter=\(filter)&per_page=50&page=\(currentPage)"
            let batch = try await get(path, as: [VikunjaTask].self)
            all.append(contentsOf: batch)
            if batch.count < 50 { break }
            currentPage += 1
        }
        return all
    }

    private static func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let request = makeRequest(path)
        let (data, _) = try await send(request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func put<T: Decodable>(_ path: String, body: Data, as type: T.Type) async throws -> T {
        let request = makeRequest(path, method: "PUT", body: body)
        let (data, _) = try await send(request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func post<T: Decodable>(_ path: String, body: Data, as type: T.Type) async throws -> T {
        let request = makeRequest(path, method: "POST", body: body)
        let (data, _) = try await send(request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - API v2 (preferred flavor for everything, v1 stays as fallback)
    //
    // v2 is used for every call when the server supports it: reads try v2 and
    // fall back to v1 per-call on any non-cancellation failure; mutations
    // route by the flag with no automatic v1 retry (a timed-out v2 mutation
    // may already have been applied server-side — replaying on v1 could
    // double-create or double-toggle). Verified against Vikunja 2.4.0 before
    // writing this: create is POST /projects/{id}/tasks (no flat POST
    // /tasks), PATCH is merge-patch (explicit null clears, absent key means no
    // change), label/relation attach are body-POSTs, GET /tasks/{id} returns
    // `related_tasks` with no `expand` needed. See API_V2_MIGRATION_PLAN.md's
    // fact table for the full list.
    //
    // Gated on the server version cached by the `/info` probe (`fetchServerInfo`
    // stays on v1 forever — it's the thing that decides the version), so a
    // fresh install's first refresh is v1 and a server that answers `/info`
    // optimistically but not the rest of `/api/v2` can't break anyone on the
    // read side. `VikunjaConfig.syncActiveMirror()` clears the cached flag on
    // every account switch, since it's a single App Group key but different
    // accounts can point at servers on different versions.

    private static var v2BaseURL: String {
        let host = VikunjaConfig.host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(host)/api/v2"
    }

    private static var supportsAPIv2: Bool {
        UserDefaults(suiteName: VikunjaConfig.appGroupSuite)?
            .bool(forKey: DiagnosticLog.serverSupportsV2DefaultsKey) ?? false
    }

    /// `≥ 2.5.0` — the atomic bulk task-create endpoint and the bulk label
    /// replace that goes with it. Strictly narrower than `supportsAPIv2`
    /// (`≥ 2.4.0`), so it never has to be checked together with it. Cached the
    /// same way and cleared by the same account switch. Not `private`:
    /// `TaskStore` decides whether to coalesce a run of queued creates before
    /// it calls the API. False until the launch's first `/info` probe lands,
    /// which just means an early drain takes the per-task path.
    static var supportsBulkTaskCreate: Bool {
        UserDefaults(suiteName: VikunjaConfig.appGroupSuite)?
            .bool(forKey: DiagnosticLog.serverSupportsBulkCreateDefaultsKey) ?? false
    }

    private struct V2Page<T: Decodable>: Decodable {
        let items: [T]?
        let page: Int?
        let totalPages: Int?

        enum CodingKeys: String, CodingKey {
            case items, page
            case totalPages = "total_pages"
        }
    }

    /// Thrown by `searchDoneTasks` when the server doesn't support v2 — there
    /// is no v1 equivalent for server-side search, so `TaskStore` catches this
    /// (and any other failure) the same way: fall back to client-side
    /// filtering of what's already loaded.
    private struct V2NotAvailable: Error {}

    // MARK: - v2 request plumbing

    private static func getV2<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let request = makeRequest(path, base: v2BaseURL)
        let (data, _) = try await send(request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Loops `page`/`total_pages` until the server reports no more pages (or
    /// returns an empty page early). `pathWithoutPage` may already carry its
    /// own query (e.g. a `q=` search term) — `per_page`/`page` are appended
    /// with the right separator either way.
    private static func getV2Paged<T: Decodable>(_ pathWithoutPage: String, perPage: Int) async throws -> [T] {
        var all: [T] = []
        var page = 1
        let separator = pathWithoutPage.contains("?") ? "&" : "?"
        while true {
            let path = "\(pathWithoutPage)\(separator)per_page=\(perPage)&page=\(page)"
            let decoded: V2Page<T> = try await getV2(path, as: V2Page<T>.self)
            let items = decoded.items ?? []
            all.append(contentsOf: items)
            let totalPages = decoded.totalPages ?? 1
            if page >= max(1, totalPages) || items.isEmpty { break }
            page += 1
        }
        return all
    }

    private static func postV2<T: Decodable>(_ path: String, body: Data, as type: T.Type) async throws -> T {
        let request = makeRequest(path, method: "POST", body: body, base: v2BaseURL)
        let (data, _) = try await send(request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func postV2(_ path: String, body: Data) async throws {
        let request = makeRequest(path, method: "POST", body: body, base: v2BaseURL)
        _ = try await send(request)
    }

    /// Bodies must be `JSONSerialization` dictionaries, not `JSONEncoder`
    /// output: merge-patch needs an *explicit* `NSNull()` for a clear and an
    /// *absent* key for "no change", a distinction `Codable` can't express.
    private static func patchV2(_ path: String, body: [String: Any]) async throws {
        let request = try makeMergePatchRequest(path, body: body)
        _ = try await send(request, acceptingNotModified: true)
    }

    static func makeMergePatchRequest(
        _ path: String,
        body: [String: Any],
        base: String? = nil
    ) throws -> URLRequest {
        let data = try JSONSerialization.data(withJSONObject: body)
        return makeRequest(
            path,
            method: "PATCH",
            body: data,
            base: base ?? v2BaseURL,
            contentType: "application/merge-patch+json"
        )
    }

    private static func putV2(_ path: String, body: Data) async throws {
        let request = makeRequest(path, method: "PUT", body: body, base: v2BaseURL)
        _ = try await send(request)
    }

    private static func deleteV2(_ path: String) async throws {
        let request = makeRequest(path, method: "DELETE", base: v2BaseURL)
        _ = try await send(request)
    }

    private static func fetchAllUndoneTasksV2(knownProjectIds: Set<Int>) async throws -> [VikunjaTask] {
        // 200, not 50: at 50 a 165-task account took four round trips, which
        // undercut the whole point of leaving the fan-out behind. Verified the
        // server honours it (per_page=200 returned all 166 in one response);
        // a server that caps lower just yields more pages, since the loop
        // follows `total_pages`.
        let all: [VikunjaTask] = try await getV2Paged("/tasks?filter=done+%3D+false", perPage: 200)
        // v2 is a global endpoint, so constrain it to the same universe the v1
        // fan-out would have covered. Without this, a task in a project the app
        // doesn't list would appear with no project — and the app's own count
        // is the contract the rest of the code was written against.
        return all.filter { knownProjectIds.contains($0.projectId) }
    }

    // MARK: - Logbook search (Phase 3, v2 only)

    /// Searches the server's *entire* completion history in one call — v1 can
    /// only filter what's already been paged in locally. v2 only: throws
    /// `V2NotAvailable` when the server doesn't support it, which `TaskStore`
    /// treats the same as any other failure (fall back to client-side
    /// filtering). The query is percent-encoded and never logged — `send(_:)`
    /// already strips query strings from its log lines.
    static func searchDoneTasks(query: String) async throws -> [VikunjaTask] {
        guard supportsAPIv2 else { throw V2NotAvailable() }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? query
        let path = "/tasks?filter=done+%3D+true&q=\(encoded)&sort_by=done_at&order_by=desc&per_page=50&page=1"
        let result: V2Page<VikunjaTask> = try await getV2(path, as: V2Page<VikunjaTask>.self)
        return result.items ?? []
    }

    private static func makeRequest(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        base: String? = nil,
        contentType: String = "application/json"
    ) -> URLRequest {
        let baseURL = base ?? self.baseURL
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(VikunjaConfig.apiToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    // MARK: - Request chokepoint (logging + status validation)

    /// Every request goes through here — the single place that validates the
    /// status code and writes a diagnostic line. Successful GETs only bump a
    /// counter (see `beginRequestBatch`); everything else (mutations, non-2xx,
    /// transport errors) gets its own line. `path` is `request.url?.path`
    /// only — never `.absoluteString` and never the query string, since
    /// `fetchLabels(search:)` puts the user's search text in `?s=`.
    ///
    /// `acceptingNotModified` is opt-in per call and used only by `patchV2`: a
    /// merge-patch that changes nothing answers 304, which is the write landing
    /// in the state the caller asked for, not a failure. Nothing here sends
    /// conditional headers, so a 304 anywhere else would be a genuine surprise —
    /// and on a GET it would hand back an empty body to decode.
    private static func send(
        _ request: URLRequest,
        acceptingNotModified: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? "?"

        // Two failures here are not really failures, and both are repaired by
        // simply asking again:
        //
        // 1. **We were frozen for it.** `timeoutIntervalForResource` is a
        //    wall-clock deadline and it counts time the machine spent asleep,
        //    so a request in flight when a Mac sleeps is failed the moment it
        //    wakes, however healthy the network. Not a rare edge: build 74's
        //    overnight Mac log had 94 of these and *not one* had spent 20 s of
        //    awake time against the 25 s ceiling (longest 18.2 s, most under
        //    6 s). A closed laptop on a dock hits it every poll cycle.
        // 2. **The pooled connection died under us** (`networkConnectionLost`).
        //    A fresh request builds a new connection and gets through; the same
        //    iOS log shows one on a reused HTTP/3 connection, failing at 8.8 s
        //    with the response never completing, immediately after which an
        //    organic refresh succeeded in ~1 s.
        //
        // Deliberately **not** retried: a timeout that ran while awake. That
        // one already spent the entire resource budget establishing that the
        // network isn't answering, and a second pass just makes the user wait
        // 50 s for the same answer instead of 25.
        //
        // **GETs only.** A mutation that failed may perfectly well have landed
        // on the server; replaying it could double-create or double-toggle.
        // Same reasoning that keeps v2 mutations from falling back to v1 — a
        // transport failure says nothing about whether the write applied. One
        // extra pass, too: failing the retry the same way is a real failure
        // for the caller to handle.
        let retryAllowed = (method == "GET")
        var retried = false

        while true {
            let stopwatch = DiagnosticLog.Stopwatch()
            // Per-request delegate purely to collect metrics; see `phaseSummary`.
            let metrics = MetricsCollector()

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request, delegate: metrics)
            } catch {
                let elapsed = DiagnosticLog.elapsed(stopwatch)
                // The freeze check is what narrows case 1 from "any
                // connectivity blip" to "we were frozen for it": both hold.
                let frozenThroughIt = VeyrnError.isConnectivityOnly(error)
                    && DiagnosticLog.wasFrozen(during: stopwatch)
                let willRetry = (frozenThroughIt || VeyrnError.isConnectionLost(error))
                    && retryAllowed && !retried

                let line = "✗ \(VeyrnError.logDescription(for: error)) \(method) \(path) (\(elapsed)) \(metrics.phaseSummary())"
                    + (willRetry ? " — retrying" : "")
                // A cancelled request is expected — we quit, switched accounts,
                // or a task group tore down its siblings. Logging it at ERROR
                // made routine teardown read as failure. A request we're about
                // to reissue isn't a failure either, and logging it as one
                // buried the real errors in a night's worth of sleep noise.
                if VeyrnError.isCancellation(error) || willRetry {
                    DiagnosticLog.info(line)
                } else {
                    DiagnosticLog.error(line)
                }

                if willRetry {
                    retried = true
                    continue
                }
                throw error
            }

            let elapsed = DiagnosticLog.elapsed(stopwatch)
            guard let http = response as? HTTPURLResponse else {
                DiagnosticLog.error("✗ non-HTTP response \(method) \(path) (\(elapsed))")
                throw APIError.badStatus(-1)
            }
            let noChange = acceptingNotModified && http.statusCode == 304
            guard (200...299).contains(http.statusCode) || noChange else {
                DiagnosticLog.warn("← \(http.statusCode) \(method) \(path) (\(elapsed)) \(metrics.phaseSummary())")
                throw APIError.badStatus(http.statusCode)
            }

            if method == "GET" {
                bumpRequestCounter(bytes: data.count)
            } else {
                DiagnosticLog.info("← \(http.statusCode) \(method) \(path) (\(elapsed))\(noChange ? " no change" : "")")
            }
            return (data, http)
        }
    }

    // MARK: - Request batch counters (for TaskStore.refresh()'s summary line)

    private static let counterLock = NSLock()
    private static var requestCount = 0
    private static var bytesReceived = 0

    static func beginRequestBatch() {
        counterLock.lock()
        requestCount = 0
        bytesReceived = 0
        counterLock.unlock()
    }

    static func takeRequestBatch() -> (count: Int, bytes: Int) {
        counterLock.lock()
        defer { counterLock.unlock() }
        return (requestCount, bytesReceived)
    }

    private static func bumpRequestCounter(bytes: Int) {
        counterLock.lock()
        requestCount += 1
        bytesReceived += bytes
        counterLock.unlock()
    }

    enum APIError: Error, LocalizedError {
        case badStatus(Int)

        var statusCode: Int {
            if case .badStatus(let code) = self { return code }
            return -1
        }

        var isClient4xx: Bool {
            (400...499).contains(statusCode)
        }

        /// The credential was refused. **Vikunja answers 401 for an
        /// under-scoped API token, not 403** — a token missing "Tasks →
        /// Update" reads tasks fine and 401s every write — so these two are
        /// one case, never distinguishable as "bad token" vs "bad
        /// permissions". A queued write that hits this is still perfectly
        /// good and must be kept: it lands once the token is fixed.
        var isAuthFailure: Bool {
            statusCode == 401 || statusCode == 403
        }

        /// The task really is gone server-side — the only 4xx where silently
        /// discarding a queued edit is the right answer.
        var isGone: Bool {
            statusCode == 404 || statusCode == 410
        }

        /// Server asking us to slow down. Transient, so a queued write waits
        /// rather than being thrown away.
        var isRateLimited: Bool {
            statusCode == 429
        }

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "Server returned HTTP \(code)"
            }
        }
    }
}

/// Collects `URLSessionTaskMetrics` for one request so a failure can say *which
/// phase* stalled instead of leaving us to guess between a dead pooled
/// connection, a blackholed route, and a resolver hang. Attached as a
/// per-request delegate by `VikunjaAPI.send(_:)` and read only on failure.
///
/// Deliberately logs **no** host and **no** remote address — only phase names,
/// durations, and booleans.
final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var last: URLSessionTaskTransactionMetrics?
    private var transactionCount = 0

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        last = metrics.transactionMetrics.last
        transactionCount = metrics.transactionMetrics.count
        lock.unlock()
    }

    func phaseSummary() -> String {
        lock.lock()
        let m = last
        let attempts = transactionCount
        lock.unlock()

        // Delivery of didFinishCollecting isn't strictly ordered before
        // `data(for:)` returns, so this can legitimately be empty.
        guard let m else { return "[metrics: none collected]" }

        var parts: [String] = ["reused=\(m.isReusedConnection)"]
        if let proto = m.networkProtocolName { parts.append(proto) }

        func duration(_ from: Date?, _ to: Date?) -> String? {
            guard let from, let to else { return nil }
            return String(format: "%.0f ms", to.timeIntervalSince(from) * 1000)
        }

        // The whole point: a phase with a start and no end is where it died.
        let phases: [(String, Date?, Date?)] = [
            ("dns", m.domainLookupStartDate, m.domainLookupEndDate),
            ("connect", m.connectStartDate, m.connectEndDate),
            ("tls", m.secureConnectionStartDate, m.secureConnectionEndDate),
            ("request", m.requestStartDate, m.requestEndDate),
            ("response", m.responseStartDate, m.responseEndDate),
        ]
        var stalled = false
        for (name, start, end) in phases {
            if let d = duration(start, end) {
                parts.append("\(name) \(d)")
            } else if start != nil, end == nil {
                parts.append("\(name) ✗ never completed")
                stalled = true
                break
            }
        }
        if !stalled {
            if m.domainLookupStartDate == nil, m.connectStartDate == nil, m.requestStartDate == nil {
                // Never even attempted a connection — the request sat waiting
                // for one. This is the shape a stale/exhausted connection pool
                // would take.
                parts.append("no connection attempt")
            } else if m.requestEndDate != nil, m.responseStartDate == nil {
                parts.append("response ✗ never started")
            }
        }
        if attempts > 1 { parts.append("attempts=\(attempts)") }
        return "[" + parts.joined(separator: ", ") + "]"
    }
}
