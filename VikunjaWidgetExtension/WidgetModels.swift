import Foundation
import WidgetKit

// MARK: - Widget display models (base types VikunjaTask/VikunjaLabel/VikunjaProject are in VikunjaCore)

struct TaskEntryItem: Identifiable, Codable {
    let id: Int
    let title: String
    let projectName: String
    let tags: [String]
    let dueDate: Date
    /// Vikunja's 1–5 scale; 0 (or nil upstream) means no priority and draws no chip.
    var priority: Int = 0
    /// True when the task still has a reminder in the future — drives the bell glyph.
    var hasReminder: Bool = false
    var isPendingUndo: Bool = false
}

struct TaskGroup {
    let label: String
    let tasks: [TaskEntryItem]
}

// MARK: - Timeline entry

struct VikunjaEntry: TimelineEntry {
    let date: Date
    let taskGroups: [TaskGroup]
    let error: String?
    let todayCount: Int

    static let placeholder = VikunjaEntry(
        date: Date(),
        taskGroups: [
            TaskGroup(label: "Today", tasks: [
                TaskEntryItem(id: 1, title: "Review project proposal", projectName: "Work", tags: ["urgent"], dueDate: Date(), priority: 3, hasReminder: true),
                TaskEntryItem(id: 2, title: "Schedule dentist", projectName: "Personal", tags: [], dueDate: Date()),
            ]),
            TaskGroup(label: "Tomorrow", tasks: [
                TaskEntryItem(id: 3, title: "Call insurance company", projectName: "Finance", tags: [], dueDate: Date(), priority: 1),
            ]),
        ],
        error: nil,
        todayCount: 2
    )
}
