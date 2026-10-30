import Foundation
import PickupCore
import UserNotifications

/// Which finished calls count as missed (notification and red dot on the menu bar icon).
enum MissedCalls {
    /// An incoming call nobody answered. Declined on this Mac is a choice, not missed.
    static func isMissed(_ call: CallInfo) -> Bool { isMissed(direction: call.direction, endReason: call.endReason) }

    static func isMissed(direction: CallDirection, endReason: CallEndReason?) -> Bool {
        direction == .incoming && endReason == .missed
    }
}

/// Posts a local notification for missed calls, only when the user allowed notifications.
final class MissedCallNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MissedCallNotifier()
    static let enabledKey = "notifyMissedCalls"
    private static let category = "missed-call"
    private static let callBackAction = "call-back"
    private static let numberKey = "number"

    /// Call once at launch: shows banners while the app is "active" (menu bar apps always are).
    func install() {
        guard PermissionsModel.notificationsAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let callBack = UNNotificationAction(identifier: Self.callBackAction,
                                            title: String(localized: "Call Back", comment: "Button of the missed-call notification: calls the number back on the phone."))
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [callBack], intentIdentifiers: [])])
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
    }

    /// `number` as the phone reported it (formatted for display here); nil when withheld.
    func notifyMissed(name: String?, number rawNumber: String?) {
        let number = rawNumber.map { PhoneNumberFormat.display($0) }
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
            if let rawNumber, DialNumber(rawNumber).map({ !$0.isServiceCode }) == true {
                content.categoryIdentifier = Self.category   // "Call Back" only for a dialable number
                content.userInfo = [Self.numberKey: rawNumber]
            }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == Self.callBackAction,
              let number = response.notification.request.content.userInfo[Self.numberKey] as? String else { return }
        await MainActor.run { AppModel.shared.callBack(number) }
    }
}
