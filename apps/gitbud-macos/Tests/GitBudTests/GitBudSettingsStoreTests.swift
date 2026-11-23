import XCTest
import GitKittieKit
@testable import GitBudCore

final class GitBudSettingsStoreTests: XCTestCase {
    private func store() -> GitBudSettingsStore {
        let suite = "gitbud-settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let magicKeychain = KeychainService(service: suite, account: "magic-api-key")
        let providerKeychain = KeychainService(service: suite, account: "provider-access-token")
        // Nothing from a test stays behind in the defaults or the login keychain.
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? magicKeychain.delete()
            try? providerKeychain.delete()
        }
        return GitBudSettingsStore(defaults: defaults, magicKeychain: magicKeychain, providerKeychain: providerKeychain)
    }

    func testMagicDefaultsToTheOnDeviceModelWhenThisMacHasIt() {
        let expected: AIPontProvider = OnDeviceAI.isAvailable ? .onDevice : .openAICompatible
        XCTAssertEqual(store().loadMagicSettings().provider, expected)
    }

    func testASavedProviderAlwaysWins() throws {
        let store = store()
        try store.saveMagicSettings(GitBudMagicSettings(provider: .anthropic, model: "m", endpoint: "", apiKey: ""))
        XCTAssertEqual(store.loadMagicSettings().provider, .anthropic)
    }
}
