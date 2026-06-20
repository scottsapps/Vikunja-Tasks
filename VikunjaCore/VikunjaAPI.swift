import Foundation

enum VikunjaAPI {
    private static var baseURL: String { VikunjaConfig.baseURL }

    // MARK: - Projects

    static func createProject(title: String) async throws -> VikunjaProject {
        let body = try JSONSerialization.data(withJSONObject: ["title": title])
        return try await put("/projects", body: body, as: VikunjaProject.self)
    }

    static func deleteProject(id: Int) async throws {
        let request = makeRequest("/projects/\(id)", method: "DELETE")
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        guard let http, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus(http?.statusCode ?? -1)
        }
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
        return try await withThrowingTaskGroup(of: [VikunjaTask].self) { group in
            for project in projectList {
                group.addTask { try await fetchTasks(projectId: project.id, done: false) }
            }
            var combined: [VikunjaTask] = []
            for try await batch in group { combined.append(contentsOf: batch) }
            return combined
        }
    }

    // MARK: - Tasks (done / logbook)

    static func fetchDoneTasks(page: Int = 1) async throws -> [VikunjaTask] {
        let projectList = try await fetchAllProjects()
        let tasks: [VikunjaTask] = try await withThrowingTaskGroup(of: [VikunjaTask].self) { group in
            for project in projectList {
                group.addTask { try await fetchTasks(projectId: project.id, done: true, page: page) }
            }
            var combined: [VikunjaTask] = []
            for try await batch in group { combined.append(contentsOf: batch) }
            return combined
        }
        return tasks.sorted { ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast) }
    }

    // MARK: - Single task (includes related_tasks from the server)

    static func fetchTask(id: Int) async throws -> VikunjaTask {
        return try await get("/tasks/\(id)", as: VikunjaTask.self)
    }

    // MARK: - Mutations

    static func deleteTask(id: Int) async throws {
        let request = makeRequest("/tasks/\(id)", method: "DELETE")
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        guard let http, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus(http?.statusCode ?? -1)
        }
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
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        guard let http, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus(http?.statusCode ?? -1)
        }
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
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    // MARK: - Task relations (subtasks)

    static func addRelation(taskId: Int, otherTaskId: Int, kind: String = "subtask") async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "other_task_id": otherTaskId,
            "relation_kind": kind,
        ])
        let request = makeRequest("/tasks/\(taskId)/relations", method: "PUT", body: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    static func removeRelation(taskId: Int, otherTaskId: Int, kind: String = "subtask") async throws {
        let request = makeRequest("/tasks/\(taskId)/relations/\(kind)/\(otherTaskId)", method: "DELETE")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    // MARK: - Date helpers

    /// Snaps a date to 8 PM Eastern time, preserving the calendar day in Eastern time.
    static func applyDefaultTime(_ date: Date) -> Date {
        let eastern = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = eastern
        var comps = cal.dateComponents([.year, .month, .day], from: date)
        comps.hour = 20
        comps.minute = 0
        comps.second = 0
        comps.timeZone = eastern
        return cal.date(from: comps) ?? date
    }

    // MARK: - Task update

    static func updateTask(id: Int, update: TaskUpdate) async throws -> VikunjaTask {
        let body = try JSONSerialization.data(withJSONObject: update.jsonBody)
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
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        guard let http, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus(http?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func put<T: Decodable>(_ path: String, body: Data, as type: T.Type) async throws -> T {
        let request = makeRequest(path, method: "PUT", body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        guard let http, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus(http?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func post<T: Decodable>(_ path: String, body: Data, as type: T.Type) async throws -> T {
        let request = makeRequest(path, method: "POST", body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        guard let http, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus(http?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func makeRequest(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(VikunjaConfig.apiToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
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
