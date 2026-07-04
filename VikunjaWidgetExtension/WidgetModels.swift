import Foundation
import WidgetKit

// MARK: - Widget display models (base types VikunjaTask/VikunjaLabel/VikunjaProject are in VikunjaCore)

struct TaskEntryItem: Identifiable, Codable {
    let id: Int
    let title: String
    let projectName: String
    let tags: [String]
    let dueDate: Date
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
                TaskEntryItem(id: 1, title: "Review project proposal", projectName: "Work", tags: ["urgent"], dueDate: Date()),
                TaskEntryItem(id: 2, title: "Schedule dentist", projectName: "Personal", tags: [], dueDate: Date()),
            ]),
            TaskGroup(label: "Tomorrow", tasks: [
                TaskEntryItem(id: 3, title: "Call insurance company", projectName: "Finance", tags: [], dueDate: Date()),
            ]),
        ],
        error: nil,
        todayCount: 2
    )
}
