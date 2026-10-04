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
    var repeatAfter: Int?
    var repeatMode: Int?
    var relatedTasks: [String: [VikunjaTask]]?

    enum CodingKeys: String, CodingKey {
        case id, title, done, labels, description, priority, reminders
        case dueDate = "due_date"
        case projectId = "project_id"
        case updated
        case repeatAfter = "repeat_after"
        case repeatMode = "repeat_mode"
        case relatedTasks = "related_tasks"
    }

    var effectiveDueDate: Date? {
        guard let str = dueDate, !str.hasPrefix("0001") else { return nil }
        return ISO8601DateFormatter().date(from: str)
    }

    /// True while at least one reminder is still ahead of us. Fired reminders stop
    /// counting, so an overdue task doesn't keep advertising a ping that already came.
    var hasFutureReminder: Bool {
        let now = Date()
        return reminders?.contains { ($0.date ?? .distantPast) > now } ?? false
    }

    var updatedDate: Date? {
        guard let str = updated else { return nil }
        return ISO8601DateFormatter().date(from: str)
    }

    var subtasks: [VikunjaTask] {
        relatedTasks?["subtask"] ?? []
    }

    /// True when this task is itself a subtask of another task (has a "parenttask" relation).
    /// Used to hide subtasks from top-level lists (Inbox/Project/Today), where they'd
    /// otherwise show up as duplicate-looking standalone tasks alongside their parent.
    var isSubtask: Bool {
        !(relatedTasks?["parenttask"] ?? []).isEmpty
    }

    var subtaskProgress: (done: Int, total: Int) {
        let all = subtasks
        return (all.filter { $0.done }.count, all.count)
    }
}

struct VikunjaLabel: Codable, Identifiable {
    let id: Int
    let title: String
    let hexColor: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case hexColor = "hex_color"
    }
}

struct VikunjaProject: Codable, Identifiable, Equatable {
    let id: Int
    let title: String
    let hexColor: String?
    /// Raw `parent_project_id` off the wire. **Optional on purpose**: the
    /// widget cache and the Watch's config store both decode `[VikunjaProject]`
    /// from data an older build wrote with no such key, and synthesized
    /// `Codable` treats an optional as `decodeIfPresent` — a non-optional would
    /// throw and take the whole cached list down (blank widget, blank Watch).
    /// Never test this directly; use `parentId`.
    let parentProjectId: Int?
    /// Raw `is_archived` off the wire. **Optional for the same reason as
    /// `parentProjectId`**: caches written by a build that predates this field
    /// decode without it, and a non-optional would throw and take the whole
    /// cached list down. Absent ⇒ not archived, which is the safe default —
    /// it shows a project rather than hiding one. Never test this directly;
    /// use `isArchivedProject`.
    let isArchived: Bool?
    /// Raw `max_permission` off the wire: the most the token's user may do in
    /// this project (0 = read, 1 = read/write, 2 = admin). Only sent when the
    /// list was fetched with `expand=permissions`, so it is absent from older
    /// caches and `null` when the server didn't compute it. **Optional for the
    /// same reason as `parentProjectId`.** Absent ⇒ writable, which keeps
    /// today's behavior; a write the server refuses is still caught by the
    /// outbox's 403 handling. Never test this directly; use `isReadOnly`.
    let maxPermission: Int?

    enum CodingKeys: String, CodingKey {
        case id, title
        case hexColor = "hex_color"
        case parentProjectId = "parent_project_id"
        case isArchived = "is_archived"
        case maxPermission = "max_permission"
    }

    /// Shared with the token's user as read-only — tasks can be viewed but not
    /// created, edited, completed or deleted. Since Vikunja 2.7 this includes
    /// a read-only share on a child of a project the user can write to, which
    /// older servers wrongly let through.
    var isReadOnly: Bool { maxPermission == 0 }

    /// Vikunja archives a project to mean "done with this, get it out of the
    /// way": it stays readable but goes read-only. Veyrn has no archive UI, so
    /// archived projects are filtered out at the API boundary — see
    /// `VikunjaAPI.fetchAllProjects()`.
    var isArchivedProject: Bool { isArchived == true }

    /// Nil for a top-level project. Vikunja's Go server sends `0` (the zero
    /// value for an omitted int), not `null`, and project ids are always
    /// positive — so both `nil` and `0` mean "no parent".
    var parentId: Int? {
        guard let parentProjectId, parentProjectId > 0 else { return nil }
        return parentProjectId
    }

    static func == (lhs: VikunjaProject, rhs: VikunjaProject) -> Bool {
        lhs.id == rhs.id
    }
}

struct VikunjaReminder: Codable {
    let reminder: String   // ISO8601 timestamp

    var date: Date? {
        ISO8601DateFormatter().date(from: reminder)
    }
}

/// Response of `GET /info` (v2 first, v1 fallback — see
/// `VikunjaAPI.fetchServerInfo()`). Only the fields Veyrn uses are decoded.
struct VikunjaServerInfo: Codable {
    let version: String
    /// The server's `service.maxitemsperpage` — the most items any paginated
    /// endpoint returns per page, whatever `per_page` asks for. Optional so a
    /// server that leaves it out still decodes.
    let maxItemsPerPage: Int?
    /// True when the answer came from `/api/v2/info`. Not on the wire: set by
    /// `fetchServerInfo()`. A server that answers on v2 has the v2 API, which
    /// matters once the version string alone can't say so (a dev build like
    /// "unstable" parses as unknown).
    var servedByV2 = false

    enum CodingKeys: String, CodingKey {
        case version
        case maxItemsPerPage = "max_items_per_page"
    }
}

struct VikunjaUser: Codable {
    let id: Int
    let username: String
    let name: String?

    var displayName: String {
        let n = name?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? username : n
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
    var repeatAfter: Int?       // nil = no change
    var clearRepeat: Bool = false
    var repeatMode: Int?
}
