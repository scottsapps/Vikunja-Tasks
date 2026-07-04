#if os(iOS)
import BackgroundTasks
import WidgetKit

enum BackgroundRefresh {
    static let taskId = "net.angstreich.VikunjaWidgetApp.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            handle(task as! BGAppRefreshTask)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()   // always queue the next run
        let work = Task {
            guard VikunjaConfig.isConfigured else {
                task.setTaskCompleted(success: true); return
            }
            do {
                let projects = try await VikunjaAPI.fetchAllProjects()
                let tasks = try await VikunjaAPI.fetchAllUndoneTasks(projects: projects)
                WidgetCache.save(tasks: tasks, projects: projects)
                await ReminderScheduler.sync(tasks: tasks)
                WatchSessionProvider.shared.pushSnapshot(tasks: tasks, projects: projects)
                WidgetCenter.shared.reloadAllTimelines()
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = { work.cancel() }
    }
}
#endif
