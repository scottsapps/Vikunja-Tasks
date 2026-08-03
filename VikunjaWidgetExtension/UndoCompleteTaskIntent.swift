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
        DiagnosticLog.info("UndoCompleteTaskIntent task \(taskId) → ok")
        // Completing here cancelled the task's reminders; undoing puts back the
        // ones still in the future. Best effort — if a refresh has already
        // rewritten the cache without this task, the app's next
        // `ReminderScheduler.sync` restores them instead.
        if let task = WidgetCache.load()?.tasks.first(where: { $0.id == taskId }) {
            await ReminderStore.schedule(task: task, reason: "completion undone")
        }
        SharedState.remove(taskId: taskId)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
