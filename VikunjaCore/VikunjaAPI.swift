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

    // MARK: - Projects

    static func createProject(title: String) async throws -> VikunjaProject {
        let body = try JSONSerialization.data(withJSONObject: ["title": title])
        return try await put("/projects", body: body, as: VikunjaProject.self)
    }

    static func deleteProject(id: Int) async throws {
        let request = makeRequest("/projects/\(id)", method: "DELETE")
        _ = try await send(request)
    }

    static func fetchAllProjects() async throws -> [VikunjaProject] {
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
                // Cancellation is our own doing — don't paper over it with a
                // second full fetch.
                if VeyrnError.isCancellation(error) { throw error }
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
        let projectList = try await fetchAllProjects()
        let tasks = try await fetchTasksAcrossProjects(projectList.map(\.id), done: true, page: page)
        return tasks.sorted { ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast) }
    }

    // MARK: - Single task (includes related_tasks from the server)

    static func fetchTask(id: Int) async throws -> VikunjaTask {
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
        let request = makeRequest("/tasks/\(id)", method: "DELETE")
        _ = try await send(request)
    }

    static func completeTask(id: Int) async throws {
        try await setDone(id: id, done: true)
    }

    static func reopenTask(id: Int) async throws {
        try await setDone(id: id, done: false)
    }

    /// Toggle done state while preserving every other field. Vikunja's Go server
    /// treats fields omitted from the JSON body as zero-valued (e.g. `due_date`
    /// becomes `0001-01-01`), which silently wipes the due date. The web client
    /// avoids this by sending the full task object — we mirror that here by
    /// fetching the current task and re-posting it with `done` overridden.
    private static func setDone(id: Int, done: Bool) async throws {
        var task = try await fetchTask(id: id)
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
        let data = try JSONSerialization.data(withJSONObject: body)
        let task = try await put("/projects/\(projectId)/tasks", body: data, as: VikunjaTask.self)

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

    // MARK: - Labels

    static func fetchLabels(search: String = "") async throws -> [VikunjaLabel] {
        let encoded = search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? search
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
        return try await put("/labels", body: body, as: VikunjaLabel.self)
    }

    static func addLabelToTask(taskId: Int, labelId: Int) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["label_id": labelId])
        let request = makeRequest("/tasks/\(taskId)/labels", method: "PUT", body: body)
        _ = try await send(request)
    }

    // MARK: - Task relations (subtasks)

    static func addRelation(taskId: Int, otherTaskId: Int, kind: String = "subtask") async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "other_task_id": otherTaskId,
            "relation_kind": kind,
        ])
        let request = makeRequest("/tasks/\(taskId)/relations", method: "PUT", body: body)
        _ = try await send(request)
    }

    static func removeRelation(taskId: Int, otherTaskId: Int, kind: String = "subtask") async throws {
        let request = makeRequest("/tasks/\(taskId)/relations/\(kind)/\(otherTaskId)", method: "DELETE")
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

    static func updateTask(id: Int, update: TaskUpdate) async throws -> VikunjaTask {
        // Vikunja's Go server treats every field omitted from the JSON body as
        // zero-valued, so a partial update silently wipes unrelated fields — e.g.
        // adding a reminder (body has `reminders` but no `due_date`) clears the
        // due date, and adding a due date clears existing reminders. Mirror the
        // web client / `setDone`: fetch the current task, overlay only the changed
        // fields, and re-post the full object so nothing gets clobbered.
        let iso = ISO8601DateFormatter()
        var task = try await fetchTask(id: id)

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
        return try await fetchTask(id: id)
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

    // MARK: - API v2 (undone-task fetch only)
    //
    // Veyrn stays on v1 for everything else. v2 is used for exactly one call —
    // the undone-task fetch — because v1's `/tasks/all` is broken, forcing a
    // per-project fan-out, and that fan-out is what stalls on macOS. Verified
    // against Vikunja 2.4.0: the response is a `{items, page, total_pages, …}`
    // envelope, tasks carry `related_tasks` (so subtask detection and progress
    // badges keep working), and the v1 `filter=done = false` syntax is accepted.
    //
    // Gated on the server version cached by the `/info` probe, and any failure
    // falls back to the v1 fan-out — so a server that answers `/info`
    // optimistically but not `/tasks` can't break anyone.

    private static var v2BaseURL: String {
        let host = VikunjaConfig.host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(host)/api/v2"
    }

    private static var supportsAPIv2: Bool {
        UserDefaults(suiteName: VikunjaConfig.appGroupSuite)?
            .bool(forKey: DiagnosticLog.serverSupportsV2DefaultsKey) ?? false
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

    private static func fetchAllUndoneTasksV2(knownProjectIds: Set<Int>) async throws -> [VikunjaTask] {
        var all: [VikunjaTask] = []
        var page = 1
        while true {
            // 200, not 50: at 50 a 165-task account took four round trips,
            // which undercut the whole point of leaving the fan-out behind.
            // Verified the server honours it (per_page=200 returned all 166
            // in one response); a server that caps lower just yields more
            // pages, since the loop follows `total_pages`.
            let path = "/tasks?filter=done+%3D+false&per_page=200&page=\(page)"
            let request = makeRequest(path, base: v2BaseURL)
            let (data, _) = try await send(request)
            let decoded = try JSONDecoder().decode(V2Page<VikunjaTask>.self, from: data)
            all.append(contentsOf: decoded.items ?? [])
            let totalPages = decoded.totalPages ?? 1
            if page >= max(1, totalPages) || (decoded.items ?? []).isEmpty { break }
            page += 1
        }
        // v2 is a global endpoint, so constrain it to the same universe the v1
        // fan-out would have covered. Without this, a task in a project the app
        // doesn't list would appear with no project — and the app's own count
        // is the contract the rest of the code was written against.
        return all.filter { knownProjectIds.contains($0.projectId) }
    }

    private static func makeRequest(_ path: String, method: String = "GET", body: Data? = nil, base: String? = nil) -> URLRequest {
        let baseURL = base ?? self.baseURL
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(VikunjaConfig.apiToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
    private static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? "?"
        let stopwatch = DiagnosticLog.Stopwatch()
        // Per-request delegate purely to collect metrics; see `phaseSummary`.
        let metrics = MetricsCollector()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: metrics)
        } catch {
            let elapsed = DiagnosticLog.elapsed(stopwatch)
            let line = "✗ \(VeyrnError.logDescription(for: error)) \(method) \(path) (\(elapsed)) \(metrics.phaseSummary())"
            // A cancelled request is expected — we quit, switched accounts, or
            // a task group tore down its siblings. Logging it at ERROR made
            // routine teardown read as failure.
            if VeyrnError.isCancellation(error) {
                DiagnosticLog.info(line)
            } else {
                DiagnosticLog.error(line)
            }
            throw error
        }

        let elapsed = DiagnosticLog.elapsed(stopwatch)
        guard let http = response as? HTTPURLResponse else {
            DiagnosticLog.error("✗ non-HTTP response \(method) \(path) (\(elapsed))")
            throw APIError.badStatus(-1)
        }
        guard (200...299).contains(http.statusCode) else {
            DiagnosticLog.warn("← \(http.statusCode) \(method) \(path) (\(elapsed)) \(metrics.phaseSummary())")
            throw APIError.badStatus(http.statusCode)
        }

        if method == "GET" {
            bumpRequestCounter(bytes: data.count)
        } else {
            DiagnosticLog.info("← \(http.statusCode) \(method) \(path) (\(elapsed))")
        }
        return (data, http)
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
