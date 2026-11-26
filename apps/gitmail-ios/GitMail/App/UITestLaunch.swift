#if DEBUG
import Foundation
import MailAccounts
import MailExtraction
import MailProvider
import MailStore

/// UI tests only, and only in Debug builds: a fresh mail folder in the app's temporary folder,
/// a Keychain service of its own, its own preferences, and the local test server's CA (from
/// `GKM_TEST_CA_PEM_BASE64`, the PEM the test runner read) trusted for connections. Real servers, real Keychain, real
/// store; nothing is faked. A Release build has no such switch.
enum UITestLaunch {
    @MainActor
    static func session() -> MobileSession {
        let environment = ProcessInfo.processInfo.environment
        // A named store (`-uiTestStoreName <name>`) is kept across launches of one test, so a
        // test can relaunch with another text size; otherwise every launch starts empty.
        let arguments = ProcessInfo.processInfo.arguments
        let name = arguments.firstIndex(of: "-uiTestStoreName").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-\(name ?? UUID().uuidString)", isDirectory: true)
        let isFresh = !FileManager.default.fileExists(atPath: root.path)
        let locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail", isDirectory: true),
                                       deviceFolder: root.appendingPathComponent("Device", isDirectory: true))
        let suite = "app.hakobs.gitmail.uitest"
        let defaults = UserDefaults(suiteName: suite)!
        if isFresh { defaults.removePersistentDomain(forName: suite) }
        var services = AccountServices.live
        services.defaults = defaults
        services.credentials = KeychainCredentialStore(service: "app.hakobs.gitmail.uitest")
        if let encoded = environment["GKM_TEST_CA_PEM_BASE64"], let pem = Data(base64Encoded: encoded) {
            let trust = TrustPolicy.customRoots(pem: [pem])
            services.connections = AccountConnections(trust: trust)
            services.verifier = AccountVerifier(connections: services.connections)
        }
        services.syncOptions = StorageBudget.standard.syncOptions
        let model = AppModel(locations: locations, extractor: InProcessTextExtractor(), services: services, notifications: nil)
        if let subject = environment["GKM_UITEST_NOTIFICATION_SUBJECT"] { openNotifications(about: subject, in: model) }
        return MobileSession(model: model, defaults: defaults, freeSpace: { _ in nil })
    }

    /// The Darwin notification a UI test posts for "the notification was tapped" (GKM-085).
    static let notificationTapped = "app.hakobs.gitmail.uitest.notificationTapped"
    @MainActor private static var notificationModel: AppModel?
    @MainActor private static var notificationSubject = ""

    /// A tapped notification, for the UI tests: a test can't tap a mail notification the app
    /// posts (a UI test launch posts none, and Springboard delivers the tap). On
    /// `notificationTapped` the message with the subject in `GKM_UITEST_NOTIFICATION_SUBJECT` is
    /// opened through `AppModel.openFromNotification`, the call `MailNotificationResponder` makes
    /// for a real tap.
    @MainActor private static func openNotifications(about subject: String, in model: AppModel) {
        notificationModel = model
        notificationSubject = subject
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            Task { @MainActor in await UITestLaunch.openTappedNotification() }
        }, notificationTapped as CFString, nil, .deliverImmediately)
    }

    @MainActor private static func openTappedNotification() async {
        guard let model = notificationModel, let store = model.mailStore else { return }
        let subject = notificationSubject
        // The text index, not a page of the newest: the message may be older than any list shows.
        guard let message = try? await store.search(subject).first(where: { $0.subject == subject }) else {
            model.actionError = "UI test: no message \"\(subject)\" to open from a notification."
            return
        }
        await model.openFromNotification(message.id)
    }
}
#else
import Foundation

enum UITestLaunch {
    @MainActor
    static func session() -> MobileSession { .live() }
}
#endif
