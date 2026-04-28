import AppIntents
import WidgetKit

struct UndoCompleteTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Undo Complete Task"

    @Parameter(title: "Task ID") var taskId: Int

    init() {}

    init(taskId: Int) {
        self.taskId = taskId
    }

    func perform() async throws -> some IntentResult {
        try await VikunjaAPI.reopenTask(id: taskId)
        SharedState.remove(taskId: taskId)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
