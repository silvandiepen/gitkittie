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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-\(UUID().uuidString)", isDirectory: true)
        let locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail", isDirectory: true),
                                       deviceFolder: root.appendingPathComponent("Device", isDirectory: true))
        let suite = "app.hakobs.gitmail.uitest"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
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
        return MobileSession(model: model, defaults: defaults, freeSpace: { _ in nil })
    }
}
#else
import Foundation

enum UITestLaunch {
    @MainActor
    static func session() -> MobileSession { .live() }
}
#endif
