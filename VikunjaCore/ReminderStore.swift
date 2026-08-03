import Foundation
import UserNotifications

/// The reminder bookkeeping that both the app and the widget extension need.
/// Scheduling *policy* — diffing the server's reminders against what's pending —
/// stays in `ReminderScheduler` in the app target; what lives here is what a
/// widget has to be able to do in its own process, plus the request-building the
/// two processes must agree on.
///
/// A task completed from a widget never passes through the app, so the reminder
/// the app had already scheduled stayed armed and fired for a task finished
/// twenty minutes earlier (3.0.0 b68 logs: task 3776 completed from the widget
/// at 08:36, its reminder fired at 09:00). `UNUserNotificationCenter.current()`
/// in an app extension operates on the containing app's notification store, so
/// the extension can cancel and re-arm what the app scheduled.
enum ReminderStore {

    static let categoryId = "VIKUNJA_REMINDER"

    /// Stable identifier: "vikunja.reminder.{taskId}.{reminderISO}"
    static func identifier(taskId: Int, reminderISO: String) -> String {
        "vikunja.reminder.\(taskId).\(reminderISO)"
    }

    /// Matches a task's own reminders *and* any snoozed copy of one, whose id is
    /// `vikunja.snooze.{originalId}.{epoch}` — hence `contains` rather than
    /// `hasPrefix`. The trailing dot is what keeps task 37 from matching 3776.
    private static func matches(_ identifier: String, taskId: Int) -> Bool {
        identifier.contains("vikunja.reminder.\(taskId).")
    }

    /// Cancel every pending *and* already-delivered reminder for one task.
    @discardableResult
    static func cancel(taskId: Int, reason: String) async -> Int {
        let center = UNUserNotificationCenter.current()

        let pendingIds = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { matches($0, taskId: taskId) }
        if !pendingIds.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: pendingIds)
        }

        // A reminder that already fired sits in Notification Center with its
        // Complete and Snooze buttons still live. Leaving it there is how a
        // finished task gets completed a second time.
        let deliveredIds = await center.deliveredNotifications()
            .map(\.request.identifier)
            .filter { matches($0, taskId: taskId) }
        if !deliveredIds.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: deliveredIds)
        }

        let total = pendingIds.count + deliveredIds.count
        if total > 0 {
            DiagnosticLog.info("reminder cancelled for task \(taskId) (\(reason)): \(total)")
        }
        return total
    }

    /// Re-arm a task's still-future reminders — the mirror of `cancel`, for when
    /// a completion is undone. Best effort: already-pending requests are left
    /// alone, and a caller that can't find the task (the widget cache may have
    /// been rewritten without it) simply doesn't call this, leaving the app's
    /// next `ReminderScheduler.sync` to put the reminder back.
    static func schedule(task: VikunjaTask, reason: String) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        let pending = Set(await center.pendingNotificationRequests().map(\.identifier))

        var count = 0
        for reminder in task.reminders ?? [] {
            guard let date = reminder.date, date > Date() else { continue }
            let id = identifier(taskId: task.id, reminderISO: reminder.reminder)
            guard !pending.contains(id) else { continue }
            try? await center.add(request(id: id, taskId: task.id, title: task.title, date: date))
            count += 1
        }
        if count > 0 {
            DiagnosticLog.info("reminder rescheduled for task \(task.id) (\(reason)): \(count)")
        }
    }

    /// Single source of truth for a reminder's content. `ReminderScheduler.sync`
    /// builds its requests here too, so what the app schedules and what a widget
    /// re-arms can't drift apart.
    ///
    /// `userInfo` carries the account id because task ids collide across servers
    /// — without it, an already-delivered reminder from account A could complete
    /// account B's task 5.
    static func request(id: String, taskId: Int, title: String, date: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Reminder"
        content.body = title
        content.sound = .default
        content.userInfo = [
            "taskId": taskId,
            "accountId": VikunjaConfig.activeAccount?.id.uuidString ?? "",
        ]
        content.categoryIdentifier = categoryId

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }
}
