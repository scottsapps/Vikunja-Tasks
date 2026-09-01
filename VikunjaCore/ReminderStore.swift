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

    // MARK: - Completion tombstones
    //
    // `cancel(taskId:)` pulls a finished task's pending notification, but the
    // very next network refresh hands `ReminderScheduler.sync` a task list that
    // — against a lagging server — can still show that task as *not done*, and
    // `sync` then re-arms the reminder it just cancelled. On the Mac a completed
    // task was seen re-armed 2 s after commit this way; a device that only hears
    // about the completion through the `filter=done=false` list stays exposed
    // for as long as that list is stale (40 min in one incident). A tombstone
    // records "we cancelled this on purpose" so `sync` leaves it alone until the
    // server catches up or the window lapses.

    private static let tombstoneKey = "veyrn.reminder.tombstones"   // [String(taskId): completedAt epoch]
    private static let tombstoneTTL: TimeInterval = 20 * 60
    /// The server's `updated` on our own completion PATCH lands at ~completedAt;
    /// only a value clearly past that means the task was changed *again*
    /// elsewhere (a reopen), which retires the tombstone.
    private static let tombstoneUpdatedSlack: TimeInterval = 120

    private static var tombstoneStore: UserDefaults? {
        UserDefaults(suiteName: "group.net.angstreich.VikunjaWidgetApp")
    }

    /// Current tombstones with expired entries dropped.
    private static func liveTombstones() -> [String: Double] {
        let cutoff = Date().timeIntervalSince1970 - tombstoneTTL
        let raw = tombstoneStore?.dictionary(forKey: tombstoneKey) as? [String: Double] ?? [:]
        return raw.filter { $0.value >= cutoff }
    }

    /// Mark a task as deliberately finished. Pruning old entries happens here,
    /// on the write path.
    static func tombstone(taskId: Int) {
        var map = liveTombstones()
        map[String(taskId)] = Date().timeIntervalSince1970
        tombstoneStore?.set(map, forKey: tombstoneKey)
    }

    /// Drop a task's tombstone — for an explicit re-arm (undo, reopen, or
    /// discarding a queued completion).
    static func clearTombstone(taskId: Int) {
        var map = liveTombstones()
        guard map.removeValue(forKey: String(taskId)) != nil else { return }
        tombstoneStore?.set(map, forKey: tombstoneKey)
    }

    /// Wipe every tombstone — task ids collide across servers, so an account
    /// switch must not carry one account's "done" over onto another's task.
    static func clearAllTombstones() {
        tombstoneStore?.removeObject(forKey: tombstoneKey)
    }

    /// Whether `sync` should skip re-arming this task's reminder. `serverUpdated`
    /// is the task's `updated` from the list response: once it is clearly newer
    /// than our completion the task changed again elsewhere, so the tombstone is
    /// retired and the reminder allowed back.
    static func isTombstoned(taskId: Int, serverUpdated: Date?) -> Bool {
        guard let at = liveTombstones()[String(taskId)] else { return false }
        if let updated = serverUpdated,
           updated.timeIntervalSince1970 > at + tombstoneUpdatedSlack {
            clearTombstone(taskId: taskId)
            return false
        }
        return true
    }

    /// Cancel every pending *and* already-delivered reminder for one task.
    @discardableResult
    static func cancel(taskId: Int, reason: String) async -> Int {
        // Record the intent first: even when nothing is pending right now, the
        // next stale-list refresh must not re-arm this reminder.
        tombstone(taskId: taskId)

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
        // An explicit re-arm overrides any prior completion tombstone.
        clearTombstone(taskId: task.id)

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
