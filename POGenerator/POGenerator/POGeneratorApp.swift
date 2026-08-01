import SwiftUI
import UserNotifications

@main
struct POGeneratorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Registers as the notification delegate so PO-request notifications also show while
/// the app is in the foreground, and requests notification/badge authorization.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.requestAuthorization()
        // CloudKit delivers its subscription pushes through APNs.
        application.registerForRemoteNotifications()
        Task {
            await CloudKitManager.shared.subscribeToNewRequestNotifications()
        }
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
