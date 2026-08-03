import Foundation
import UserNotifications
import WidgetKit

final class NotificationResponseHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationResponseHandler()
    private override init() {}

    // Show banner + play sound even when the app is in the foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let notificationId = response.notification.request.identifier

        // Belt-and-braces against an already-delivered notification from a
        // different account being actioned after a switch. Notifications
        // scheduled before this field existed carry no accountId — treat
        // those as unscoped rather than blocking them.
        if let accountId = userInfo["accountId"] as? String, !accountId.isEmpty,
           accountId != VikunjaConfig.activeAccount?.id.uuidString {
            DiagnosticLog.warn("notification ignored: accountId mismatch")
            completionHandler()
            return
        }

        switch response.actionIdentifier {
        case ReminderScheduler.actionComplete:
            guard let taskId = userInfo["taskId"] as? Int else { completionHandler(); return }
            Task {
                let succeeded = (try? await VikunjaAPI.completeTask(id: taskId)) != nil
                DiagnosticLog.info("notification action COMPLETE_TASK task \(taskId) → \(succeeded ? "ok" : "failed")")
                if succeeded {
                    // The task may carry further reminders, and this one may
                    // have a snoozed copy armed — neither should survive it
                    // being completed.
                    await ReminderStore.cancel(taskId: taskId, reason: "completed from notification")
                    WidgetCenter.shared.reloadAllTimelines()
                }
                await finish(completionHandler)
            }

        case ReminderScheduler.actionSnooze:
            let snoozeDate = Date().addingTimeInterval(3600)
            let content = response.notification.request.content.mutableCopy() as! UNMutableNotificationContent
            let newId = "vikunja.snooze.\(notificationId).\(Int(snoozeDate.timeIntervalSince1970))"
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: snoozeDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: newId, content: content, trigger: trigger)
            Task {
                try? await center.add(request)
                await finish(completionHandler)
            }

        default:
            completionHandler()
        }
    }

    /// The instant this completion handler runs, UIKit updates the app snapshot
    /// and the state-restoration archive — both main-thread-only. Called from
    /// the background thread a `Task` resumes on, it trips an assertion ("Call
    /// must be made on main thread") and takes the whole app down: in 3.0.0 (68)
    /// every tap of a reminder's Complete button crashed Veyrn. The delegate
    /// method itself is invoked on the main thread, so only the branches that
    /// await the network need this hop back.
    @MainActor
    private func finish(_ completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
