import WidgetKit
import Foundation

struct WatchWidgetEntry: TimelineEntry {
    let date: Date
    let tasks: [VikunjaTask]
    let error: String?

    static let placeholder = WatchWidgetEntry(
        date: Date(),
        tasks: [
            VikunjaTask(id: 1, title: "Review proposal", done: false,
                        dueDate: ISO8601DateFormatter().string(from: Date()),
                        projectId: 1, labels: nil, description: nil,
                        updated: nil, priority: nil, reminders: nil,
                        relatedTasks: nil),
        ],
        error: nil
    )

    var todayCount: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return tasks.filter {
            guard !$0.isSubtask, let d = $0.effectiveDueDate else { return false }
            return cal.startOfDay(for: d) <= today
        }.count
    }

    var nextTask: VikunjaTask? {
        tasks
            .compactMap { task -> (Date, VikunjaTask)? in
                guard !task.isSubtask, let d = task.effectiveDueDate else { return nil }
                return (d, task)
            }
            .sorted { $0.0 < $1.0 }
            .first?.1
    }
}
