import Foundation
import UserNotifications

/// Posts a local notification for missed calls, only when the user allowed notifications.
final class MissedCallNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MissedCallNotifier()
    static let enabledKey = "notifyMissedCalls"

    /// Call once at launch: shows banners while the app is "active" (menu bar apps always are).
    func install() {
        guard PermissionsModel.notificationsAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
    }

    func notifyMissed(name: String?, number: String?) {
        guard !TestMode.isActive, PermissionsModel.notificationsAvailable,
              UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Missed call", comment: "Title of the notification for a call nobody answered.")
            content.body = name ?? number ?? String(localized: "Unknown caller")
            if name != nil, let number { content.subtitle = number }
            content.threadIdentifier = "missed-calls"
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
