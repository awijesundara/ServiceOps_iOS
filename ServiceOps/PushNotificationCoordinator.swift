import Foundation
import Combine
import UIKit
import UserNotifications

@MainActor
final class PushNotificationCoordinator: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PushNotificationCoordinator()
    @Published var deviceToken: String?
    @Published var unreadCount = 0
    @Published var pendingTarget: PushTarget?

    let deviceID: String = {
        let key = "serviceops.pushDeviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }()

    func requestAuthorization() async {
        UNUserNotificationCenter.current().delegate = self
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        } catch { /* Settings exposes current authorization state; login remains usable. */ }
    }

    func receivedDeviceToken(_ data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await MainActor.run { unreadCount += 1 }
        return [.banner, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let notificationID = info["notification_id"] as? Int
        let targetType = info["target_type"] as? String
        let targetID = info["target_id"] as? Int
        await MainActor.run {
            pendingTarget = PushTarget(
                notificationID: notificationID,
                targetType: targetType,
                targetID: targetID
            )
        }
    }
}

struct PushTarget: Equatable {
    let notificationID: Int?
    let targetType: String?
    let targetID: Int?
}

final class ServiceOpsAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushNotificationCoordinator.shared.receivedDeviceToken(deviceToken) }
    }
}
