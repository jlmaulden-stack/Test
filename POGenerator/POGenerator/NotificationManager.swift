import UserNotifications

/// Local notifications for PO requests and the app-icon badge for pending count.
/// These are device-local (no backend yet); once CloudKit is reconnected this is
/// where push/shared delivery would hook in.
enum NotificationManager {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func notifyNewRequest(requester: String, customerName: String, jobNumber: String) {
        let content = UNMutableNotificationContent()
        content.title = "New PO Request"
        content.body = "\(requester) requested a PO for \(customerName) (Job \(jobNumber))."
        content.sound = .default

        // nil trigger delivers as soon as possible.
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func updateBadge(count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count)
    }
}
