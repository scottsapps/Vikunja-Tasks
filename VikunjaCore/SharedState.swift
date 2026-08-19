import Foundation

struct PendingUndo: Codable {
    let taskId: Int
    let title: String
    let projectName: String
    let tags: [String]
    let dueDate: Date
    let completedAt: Date
    // Optional so undo entries written by an older build still decode after an update.
    var priority: Int?
    var hasReminder: Bool?
}

// Stores recently-completed tasks so the widget can show a brief undo window.
// Since AppIntents for widget buttons run in the extension process, we can use
// standard UserDefaults here — no App Group needed.
enum SharedState {
    static let undoWindow: TimeInterval = 4

    private static let key = "vikunja_pending_undo"

    static var all: [PendingUndo] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([PendingUndo].self, from: data)
        else { return [] }
        return items
    }

    static var active: [PendingUndo] {
        let cutoff = Date().addingTimeInterval(-undoWindow)
        return all.filter { $0.completedAt > cutoff }
    }

    static func add(_ item: PendingUndo) {
        var items = all.filter { $0.taskId != item.taskId }
        items.append(item)
        persist(items)
    }

    static func remove(taskId: Int) {
        persist(all.filter { $0.taskId != taskId })
    }

    static func cleanupExpired() {
        let cutoff = Date().addingTimeInterval(-undoWindow)
        persist(all.filter { $0.completedAt > cutoff })
    }

    private static func persist(_ items: [PendingUndo]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: key)
    }
}
