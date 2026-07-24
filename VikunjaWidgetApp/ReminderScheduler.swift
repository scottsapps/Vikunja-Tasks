import Foundation
import UserNotifications

/// Diffs the reminders on incoming tasks against currently scheduled
/// UNNotificationRequests, scheduling new ones and cancelling removed ones.
enum ReminderScheduler {

    static let categoryId = "VIKUNJA_REMINDER"
    static let actionComplete = "COMPLETE_TASK"
    static let actionSnooze = "SNOOZE_TASK"

    // Stable identifier: "vikunja.reminder.{taskId}.{reminderISO}"
    private static func identifier(taskId: Int, reminderISO: String) -> String {
        "vikunja.reminder.\(taskId).\(reminderISO)"
    }

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

    /// Call after every task refresh. Diffs server reminders vs. scheduled requests.
    static func sync(tasks: [VikunjaTask]) async {
        let center = UNUserNotificationCenter.current()

        // Only proceed if we have permission
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        // Build the set of (id → reminder ISO) that the server wants
        var desired: [String: (taskId: Int, title: String, date: Date)] = [:]
        for task in tasks {
            for reminder in task.reminders ?? [] {
                guard let date = reminder.date, date > Date() else { continue }
                let id = identifier(taskId: task.id, reminderISO: reminder.reminder)
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
            let content = UNMutableNotificationContent()
            content.title = "Reminder"
            content.body = info.title
            content.sound = .default
            content.userInfo = [
                "taskId": info.taskId,
                "accountId": VikunjaConfig.activeAccount?.id.uuidString ?? "",
            ]
            content.categoryIdentifier = categoryId

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: info.date
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

            try? await center.add(request)
        }
    }

    /// Cancel every pending reminder for a single task (e.g. when it is
    /// completed or deleted). A completed task is dropped from the `undoneTasks`
    /// set that `sync` diffs against, but `sync` only runs on a full network
    /// refresh — so without this the OS keeps the already-scheduled local
    /// notification and fires it before the next refresh reconciles.
    static func cancel(taskId: Int) async {
        let center = UNUserNotificationCenter.current()
        let prefix = "vikunja.reminder.\(taskId)."
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .filter { $0.identifier.hasPrefix(prefix) }
            .map(\.identifier)
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    /// Cancel all vikunja reminders (e.g. on sign-out).
    static func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .filter { $0.identifier.hasPrefix("vikunja.reminder.") }
            .map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
