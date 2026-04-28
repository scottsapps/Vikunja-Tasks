import Foundation

// MARK: - API response shapes (shared between app and widget)

struct VikunjaTask: Codable {
    var id: Int
    var title: String
    var done: Bool
    var dueDate: String?
    var projectId: Int
    var labels: [VikunjaLabel]?
    var description: String?
    var updated: String?
    var priority: Int?
    var reminders: [VikunjaReminder]?

    enum CodingKeys: String, CodingKey {
        case id, title, done, labels, description, priority, reminders
        case dueDate = "due_date"
        case projectId = "project_id"
        case updated
    }

    var effectiveDueDate: Date? {
        guard let str = dueDate, !str.hasPrefix("0001") else { return nil }
        return ISO8601DateFormatter().date(from: str)
    }

    var updatedDate: Date? {
        guard let str = updated else { return nil }
        return ISO8601DateFormatter().date(from: str)
    }
}

struct VikunjaLabel: Codable, Identifiable {
    let id: Int
    let title: String
}

struct VikunjaProject: Codable, Identifiable {
    let id: Int
    let title: String
}

struct VikunjaReminder: Codable {
    let reminder: String   // ISO8601 timestamp

    var date: Date? {
        ISO8601DateFormatter().date(from: reminder)
    }
}

// MARK: - Task update payload

struct TaskUpdate: Codable {
    var title: String?
    var description: String?
    var dueDate: Date?          // nil = no change; use clearDueDate to remove
    var clearDueDate: Bool = false
    var priority: Int?
    var clearPriority: Bool = false
    var labelIds: [Int]?
    var projectId: Int?
    var reminders: [Date]?      // nil = no change; [] = clear all reminders

    var jsonBody: [String: Any] {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let description { body["description"] = description }
        if clearDueDate {
            body["due_date"] = "0001-01-01T00:00:00Z"
        } else if let dueDate {
            body["due_date"] = ISO8601DateFormatter().string(from: dueDate)
        }
        if clearPriority {
            body["priority"] = 0
        } else if let priority {
            body["priority"] = priority
        }
        if let labelIds {
            body["labels"] = labelIds.map { ["id": $0] }
        }
        if let projectId { body["project_id"] = projectId }
        if let reminders {
            body["reminders"] = reminders.map { ["reminder": ISO8601DateFormatter().string(from: $0)] }
        }
        return body
    }
}
