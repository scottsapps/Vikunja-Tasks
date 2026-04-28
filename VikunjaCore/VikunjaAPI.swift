import Foundation

enum VikunjaAPI {
    private static var baseURL: String { VikunjaConfig.baseURL }
    private static var apiToken: String { VikunjaConfig.apiToken }

    // MARK: - Projects

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

    // MARK: - Mutations

    static func completeTask(id: Int) async throws {
        try await updateTask(id: id, done: true)
    }

    static func reopenTask(id: Int) async throws {
        try await updateTask(id: id, done: false)
    }

    static func createTask(
        projectId: Int,
        title: String,
        dueDate: Date? = nil,
        priority: Int? = nil,
        labelIds: [Int] = [],
        reminders: [Date] = []
    ) async throws -> VikunjaTask {
        var body: [String: Any] = ["title": title]
        if let dueDate {
            body["due_date"] = ISO8601DateFormatter().string(from: applyDefaultTime(dueDate))
        }
        if let priority { body["priority"] = priority }
        if !reminders.isEmpty {
            body["reminders"] = reminders.map { ["reminder": ISO8601DateFormatter().string(from: $0)] }
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

        return task
    }

    // MARK: - Labels

    static func fetchLabels(search: String = "") async throws -> [VikunjaLabel] {
        let encoded = search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? search
        let path = search.isEmpty
            ? "/labels?per_page=100"
            : "/labels?s=\(encoded)&per_page=100"
        return try await get(path, as: [VikunjaLabel].self)
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
            throw APIError.badStatus
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
        return try await post("/tasks/\(id)", body: body, as: VikunjaTask.self)
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

    private static func updateTask(id: Int, done: Bool) async throws {
        let body = try JSONEncoder().encode(["done": done])
        let request = makeRequest("/tasks/\(id)", method: "POST", body: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus
        }
    }

    private static func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let request = makeRequest(path)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func put<T: Decodable>(_ path: String, body: Data, as type: T.Type) async throws -> T {
        let request = makeRequest(path, method: "PUT", body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func post<T: Decodable>(_ path: String, body: Data, as type: T.Type) async throws -> T {
        let request = makeRequest(path, method: "POST", body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func makeRequest(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    enum APIError: Error {
        case badStatus
    }
}
