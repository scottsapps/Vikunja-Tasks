import Foundation
import UserNotifications

/// Diffs the reminders on incoming tasks against currently scheduled
/// UNNotificationRequests, scheduling new ones and cancelling removed ones.
enum ReminderScheduler {

    // Identifiers, request-building and per-task cancellation live in
    // `ReminderStore` (VikunjaCore) — the widget extension needs them too.
    static let categoryId = ReminderStore.categoryId
    static let actionComplete = "COMPLETE_TASK"
    static let actionSnooze = "SNOOZE_TASK"

    // MARK: - Public

    static func registerCategory() {
        let complete = UNNotificationAction(
            identifier: actionComplete,
            title: "Complete",
            options: [.authenticationRequired]
        )
        let snooze = UNNotificationAction(
            identifier: actionSnooze,
            title: "Snooze 1 hr",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: [complete, snooze],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else {
            return settings.authorizationStatus == .authorized
        }
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Logged on change only. `sync` runs after every refresh, so logging this
    /// unconditionally cost one line per refresh (165 of them in one Mac
    /// session) to report a value that essentially never changes.
    private static var lastLoggedAuthStatus: UNAuthorizationStatus?

    private static func logAuthorizationIfChanged(_ status: UNAuthorizationStatus) {
        guard status != lastLoggedAuthStatus else { return }
        lastLoggedAuthStatus = status
        DiagnosticLog.info("notification authorization: \(authDescription(status))")
    }

    /// Call after every task refresh. Diffs server reminders vs. scheduled requests.
    static func sync(tasks: [VikunjaTask]) async {
        let center = UNUserNotificationCenter.current()

        // Only proceed if we have permission
        let settings = await center.notificationSettings()
        logAuthorizationIfChanged(settings.authorizationStatus)
        guard settings.authorizationStatus == .authorized else { return }

        // Build the set of (id → reminder ISO) that the server wants
        var desired: [String: (taskId: Int, title: String, date: Date)] = [:]
        for task in tasks {
            // A task we just completed/deleted can still come back in a stale
            // `filter=done=false` list; don't re-arm the reminder we cancelled.
            if ReminderStore.isTombstoned(taskId: task.id, serverUpdated: task.updatedDate) { continue }
            for reminder in task.reminders ?? [] {
                guard let date = reminder.date, date > Date() else { continue }
                let id = ReminderStore.identifier(taskId: task.id, reminderISO: reminder.reminder)
                desired[id] = (task.id, task.title, date)
            }
        }

        // Get currently pending requests
        let pending = await center.pendingNotificationRequests()
        let pendingVikunja = pending.filter { $0.identifier.hasPrefix("vikunja.reminder.") }
        let pendingIds = Set(pendingVikunja.map(\.identifier))
        let desiredIds = Set(desired.keys)

        // Cancel removed
        let toCancel = pendingIds.subtracting(desiredIds)
        if !toCancel.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(toCancel))
        }

        // Schedule new
        let toAdd = desiredIds.subtracting(pendingIds)
        for id in toAdd {
            guard let info = desired[id] else { continue }
            let request = ReminderStore.request(
                id: id,
                taskId: info.taskId,
                title: info.title,
                date: info.date
            )
            try? await center.add(request)
        }

        let unchanged = pendingIds.intersection(desiredIds).count
        DiagnosticLog.info("reminders synced: \(toAdd.count) scheduled, \(toCancel.count) cancelled, \(unchanged) unchanged")
    }

    /// Cancel every pending reminder for a single task (e.g. when it is
    /// completed or deleted). A completed task is dropped from the `undoneTasks`
    /// set that `sync` diffs against, but `sync` only runs on a full network
    /// refresh — so without this the OS keeps the already-scheduled local
    /// notification and fires it before the next refresh reconciles.
    static func cancel(taskId: Int, reason: String) async {
        await ReminderStore.cancel(taskId: taskId, reason: reason)
    }

    /// Cross-check every still-pending reminder against the server, one task at
    /// a time. The `filter=done=false` list has been seen to keep returning a
    /// completed task for many minutes after the write landed — long enough for
    /// its reminder to fire — while a single-task `GET /tasks/{id}` stayed
    /// correct throughout. Run only on the nudge path: "something changed on
    /// another device" is exactly when the list may be behind. Capped so a user
    /// with many reminders can't turn one push into a long request fan-out; a
    /// per-task hiccup leaves that reminder armed rather than risk dropping a
    /// real one.
    static func verifyPending(reason: String) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }

        // `contains`, not `hasPrefix`: a snoozed copy's id is
        // `vikunja.snooze.<original>.<epoch>` and still needs verifying.
        let pending = await center.pendingNotificationRequests()
            .filter { $0.identifier.contains("vikunja.reminder.") }
        var seen = Set<Int>()
        let taskIds = pending
            .sorted {
                let a = ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture
                let b = ($1.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture
                return a < b
            }
            .compactMap { $0.content.userInfo["taskId"] as? Int }
            .filter { seen.insert($0).inserted }
            .prefix(25)
        guard !taskIds.isEmpty else { return }

        var cancelled = 0
        for id in taskIds {
            do {
                if try await VikunjaAPI.fetchTask(id: id).done {
                    await ReminderStore.cancel(taskId: id, reason: "verified done (\(reason))")
                    cancelled += 1
                }
            } catch let apiError as VikunjaAPI.APIError where apiError.isGone {
                await ReminderStore.cancel(taskId: id, reason: "verified gone (\(reason))")
                cancelled += 1
            } catch {
                // Leave this one armed — a network blip must not swallow a reminder.
            }
        }
        DiagnosticLog.info("reminders verified: \(taskIds.count) checked, \(cancelled) cancelled")
    }

    private static func authDescription(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    /// Cancel all vikunja reminders (e.g. on sign-out or account switch).
    static func cancelAll() async {
        ReminderStore.clearAllTombstones()
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .filter { $0.identifier.hasPrefix("vikunja.reminder.") }
            .map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
