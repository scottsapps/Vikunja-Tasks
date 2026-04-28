import AppIntents
import WidgetKit

struct CompleteTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete Task"

    @Parameter(title: "Task ID") var taskId: Int
    @Parameter(title: "Title") var title: String
    @Parameter(title: "Project") var projectName: String
    @Parameter(title: "Tags") var tags: [String]
    @Parameter(title: "Due Date") var dueDate: Date

    init() {}

    init(item: TaskEntryItem) {
        self.taskId = item.id
        self.title = item.title
        self.projectName = item.projectName
        self.tags = item.tags
        self.dueDate = item.dueDate
    }

    func perform() async throws -> some IntentResult {
        try await VikunjaAPI.completeTask(id: taskId)
        SharedState.add(PendingUndo(
            taskId: taskId,
            title: title,
            projectName: projectName,
            tags: tags,
            dueDate: dueDate,
            completedAt: Date()
        ))
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
