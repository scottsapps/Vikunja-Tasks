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
        do {
            try BGTaskScheduler.shared.submit(request)
            DiagnosticLog.info("BGTask scheduled (earliest +30 m)")
        } catch {
            DiagnosticLog.warn("BGTask schedule failed: \(VeyrnError.logDescription(for: error))")
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()   // always queue the next run
        DiagnosticLog.info("BGTask fired")
        let start = Date()
        let epoch = DiagnosticLog.suspensionEpoch
        let work = Task {
            guard VikunjaConfig.isConfigured else {
                DiagnosticLog.info("isConfigured=false")
                task.setTaskCompleted(success: true); return
            }
            do {
                let projects = try await VikunjaAPI.fetchAllProjects()
                let tasks = try await VikunjaAPI.fetchAllUndoneTasks(projects: projects)
                WidgetCache.save(tasks: tasks, projects: projects)
                await ReminderScheduler.sync(tasks: tasks)
                WatchSessionProvider.shared.pushSnapshot(tasks: tasks, projects: projects)
                WidgetCenter.shared.reloadAllTimelines()
                DiagnosticLog.info("BGTask done: \(tasks.count) tasks, \(DiagnosticLog.elapsedDescription(since: start, epoch: epoch))")
                task.setTaskCompleted(success: true)
            } catch {
                DiagnosticLog.warn("BGTask failed: \(VeyrnError.logDescription(for: error))")
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = {
            DiagnosticLog.warn("BGTask expired")
            work.cancel()
        }
    }
}
#endif
