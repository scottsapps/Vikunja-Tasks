import Foundation
import UserNotifications

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

        switch response.actionIdentifier {
        case ReminderScheduler.actionComplete:
            guard let taskId = userInfo["taskId"] as? Int else { completionHandler(); return }
            Task {
                try? await VikunjaAPI.completeTask(id: taskId)
                completionHandler()
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
                completionHandler()
            }

        default:
            completionHandler()
        }
    }
}
