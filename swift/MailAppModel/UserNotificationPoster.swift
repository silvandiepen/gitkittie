import UserNotifications
import MailCore

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

/// Opens the message a notification is about when it is clicked or tapped (GKM-037, MAIL-086).
/// The notification carries only the message's local id (`userInfo["message"]`); a summary of
/// several carries none and just brings the app forward.
///
/// The delegate methods are nonisolated: the system calls them on a queue of its choosing, and
/// only the id crosses to the main actor.
final class MailNotificationResponder: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let open: @Sendable (MailMessageID) async -> Void

    init(open: @escaping @Sendable (MailMessageID) async -> Void) {
        self.open = open
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let raw = response.notification.request.content.userInfo["message"] as? String,
              let id = MailMessageID(raw) else { return }
        await open(id)
    }
}

extension AppModel {
    /// Makes this model the one notifications open into. Call before launch finishes, so a
    /// notification that launched the app is not missed; the system keeps the delegate weakly,
    /// so the model holds it.
    func respondToNotifications() {
        let responder = MailNotificationResponder { [weak self] id in await self?.openFromNotification(id) }
        notificationResponder = responder
        UNUserNotificationCenter.current().delegate = responder
    }
}
