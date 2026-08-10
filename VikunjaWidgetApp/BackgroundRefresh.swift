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
        // A floor, not a promise — iOS decides when (or whether) to actually run this
        // based on usage patterns. 15 min rather than 30 because this poll is the only
        // backstop for changes made *outside* Veyrn (Vikunja's own web UI, another
        // client), which the CloudKit nudge in ChangeBeacon.swift can't observe.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            DiagnosticLog.info("BGTask scheduled (earliest +15 m)")
        } catch {
            DiagnosticLog.warn("BGTask schedule failed: \(VeyrnError.logDescription(for: error))")
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()   // always queue the next run
        DiagnosticLog.info("BGTask fired")
        let clock = DiagnosticLog.Stopwatch()
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
                DiagnosticLog.info("BGTask done: \(tasks.count) tasks, \(DiagnosticLog.elapsed(clock))")
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
