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
    /// True for the section that holds today's tasks (overdue folded in).
    /// The pager only appears when one of *these* is off the page.
    var isToday: Bool = false

    /// The first `limit` tasks across `groups`, keeping the date sections
    /// intact and dropping any section left empty. Used by the provider's
    /// upper bound and by the entry view's fit candidates.
    static func prefix(_ groups: [TaskGroup], limit: Int) -> [TaskGroup] {
        var remaining = limit
        var result: [TaskGroup] = []
        for group in groups {
            guard remaining > 0 else { break }
            let take = min(remaining, group.tasks.count)
            result.append(TaskGroup(label: group.label,
                                    tasks: Array(group.tasks.prefix(take)),
                                    isToday: group.isToday))
            remaining -= take
        }
        return result
    }

    /// `groups` with the first `count` tasks removed — the other half of
    /// paging, applied before the per-page cap.
    static func drop(_ groups: [TaskGroup], first count: Int) -> [TaskGroup] {
        var remaining = count
        var result: [TaskGroup] = []
        for group in groups {
            if remaining >= group.tasks.count {
                remaining -= group.tasks.count
                continue
            }
            result.append(TaskGroup(label: group.label,
                                    tasks: Array(group.tasks.dropFirst(remaining)),
                                    isToday: group.isToday))
            remaining = 0
        }
        return result
    }
}

// MARK: - Timeline entry

struct VikunjaEntry: TimelineEntry {
    let date: Date
    let taskGroups: [TaskGroup]
    let error: String?
    let todayCount: Int
    /// How many tasks were skipped to reach this page. 0 is the first page.
    var pageOffset: Int = 0

    static let placeholder = VikunjaEntry(
        date: Date(),
        taskGroups: [
            TaskGroup(label: DayLabel.today, tasks: [
                TaskEntryItem(id: 1, title: "Review project proposal", projectName: "Work", tags: ["urgent"], dueDate: Date(), priority: 3, hasReminder: true),
                TaskEntryItem(id: 2, title: "Schedule dentist", projectName: "Personal", tags: [], dueDate: Date()),
            ], isToday: true),
            TaskGroup(label: DayLabel.tomorrow, tasks: [
                TaskEntryItem(id: 3, title: "Call insurance company", projectName: "Finance", tags: [], dueDate: Date(), priority: 1),
            ]),
        ],
        error: nil,
        todayCount: 2
    )
}
