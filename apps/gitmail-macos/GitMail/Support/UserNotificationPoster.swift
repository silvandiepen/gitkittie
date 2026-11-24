import AppKit
import UserNotifications

/// Posts mail notifications through the system (GKM-018). Asks for permission only when there
/// is something to say, never at launch; respects whatever the person chose in System Settings.
/// The notification carries the sender and subject, nothing of the body.
struct UserNotificationPoster: MailNotificationPosting {
    func permission() async -> NotificationPermission {
        Self.map(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }

    func requestPermission() async throws -> NotificationPermission {
        let center = UNUserNotificationCenter.current()
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        return Self.map(await center.notificationSettings().authorizationStatus)
    }

    func post(_ notification: MailNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = "mail"
        if let id = notification.message { content.userInfo = ["message": id.rawValue] }
        let request = UNNotificationRequest(identifier: notification.message?.rawValue ?? UUID().uuidString, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }

    private static func map(_ status: UNAuthorizationStatus) -> NotificationPermission {
        switch status {
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        case .notDetermined: .notAsked
        @unknown default: .denied
        }
    }
}

/// The Dock badge: unread mail in Focused, nothing else (GKM-018).
enum DockBadge {
    @MainActor
    static func show(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }
}
