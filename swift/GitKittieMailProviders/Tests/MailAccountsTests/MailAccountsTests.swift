import Security
import XCTest
import MailCore
import MailProvider
@testable import MailAccounts

final class MailAccountsTests: XCTestCase {
    // MARK: Presets

    func testPresetsAreFoundByDomain() {
        XCTAssertEqual(ProviderPresets.preset(for: "ada@icloud.com")?.id, "icloud")
        XCTAssertEqual(ProviderPresets.preset(for: " ada@Me.com ")?.id, "icloud")
        XCTAssertEqual(ProviderPresets.preset(for: "ada@gmail.com")?.id, "gmail")
        XCTAssertNil(ProviderPresets.preset(for: "ada@example.com"))
        XCTAssertNil(ProviderPresets.preset(for: "not an address"))
    }

    func testICloudFollowsApplesSettings() {
        let settings = ProviderPresets.iCloud.connection(for: "ada@icloud.com")
        XCTAssertEqual(settings.kind, .iCloud)
        XCTAssertEqual(settings.imap, MailServerSettings(host: "imap.mail.me.com", port: 993, security: .implicitTLS, username: "ada@icloud.com"))
        XCTAssertEqual(settings.smtp, MailServerSettings(host: "smtp.mail.me.com", port: 587, security: .startTLS, username: "ada@icloud.com"))
        XCTAssertEqual(ProviderPresets.iCloudIMAPUsernames(for: "ada@icloud.com"), ["ada", "ada@icloud.com"],
                       "the name part first, then the full address, as Apple's page says")
    }

    func testGmailUsesImplicitTLSAndTheFullAddress() {
        let settings = ProviderPresets.gmail.connection(for: "ada@gmail.com")
        XCTAssertEqual(settings.kind, .gmail)
        XCTAssertEqual(settings.imap.host, "imap.gmail.com")
        XCTAssertEqual(settings.smtp.port, 465)
        XCTAssertEqual(settings.smtp.security, .implicitTLS)
        XCTAssertEqual(settings.imap.username, "ada@gmail.com")
    }

    func testUnknownDomainsGetAGuessAndOAuthOnlyDomainsAreKnown() {
        let guess = ProviderPresets.guess(for: "ada@example.org")
        XCTAssertEqual(guess?.imap.host, "imap.example.org")
        XCTAssertEqual(guess?.smtp.host, "smtp.example.org")
        XCTAssertEqual(guess?.smtp.security, .startTLS)
        XCTAssertNil(ProviderPresets.guess(for: "ada@"))
        XCTAssertNil(ProviderPresets.domain(of: "ada@example."))
        XCTAssertTrue(ProviderPresets.oauthOnlyDomains.contains("outlook.com"))
    }

    // MARK: Errors

    func testEachFailureBecomesItsOwnMessage() {
        let server = MailServerSettings(host: "imap.example.com", port: 993, security: .implicitTLS, username: "ada")
        func classify(_ error: MailProviderError, kind: MailAccountKind = .imap) -> AccountSetupError {
            AccountSetupError.from(error, role: .incoming, server: server, kind: kind)
        }
        XCTAssertEqual(classify(.authenticationFailed("NO")), .wrongPassword(.incoming, host: "imap.example.com", kind: .imap))
        XCTAssertEqual(classify(.connectionFailed("TLS: handshake failed")),
                       .certificateProblem(.incoming, host: "imap.example.com", detail: "TLS: handshake failed"))
        XCTAssertEqual(classify(.connectionFailed("could not connect (connection refused)")),
                       .unreachable(.incoming, host: "imap.example.com", port: 993, detail: "could not connect (connection refused)"))
        XCTAssertEqual(classify(.timedOut("greeting")), .timedOut(.incoming, host: "imap.example.com"))
        XCTAssertEqual(classify(.unsupported("no STARTTLS")), .notSecure(.incoming, host: "imap.example.com", detail: "no STARTTLS"))

        let iCloud = classify(.authenticationFailed("NO"), kind: .iCloud).message
        XCTAssertTrue(iCloud.contains("app-specific password"), iCloud)
        XCTAssertNotEqual(classify(.authenticationFailed("NO")).message, classify(.connectionFailed("x")).message)
        XCTAssertNotEqual(classify(.connectionFailed("x")).message, classify(.connectionFailed("TLS: x")).message)
    }

    // MARK: Keychain

    /// The real Keychain. Unsigned test runs cannot use the data protection keychain, so this
    /// uses the login keychain with a test-only service; the item is removed afterwards.
    ///
    /// iOS has only the data protection keychain, and it needs the app's keychain entitlement.
    /// Package tests in the iOS Simulator run in an unhosted `xctest` process that has none, so
    /// there this skips; the iOS app's hosted tests (GKM-027) run it with the entitlement.
    func testPasswordsGoToTheKeychainAndBackAsSecrets() throws {
        let store = KeychainCredentialStore(service: "app.hakobs.gitmail.tests.\(UUID().uuidString)", useDataProtectionKeychain: false)
        let account = MailAccountID()
        defer { try? store.delete(for: account) }

        let initial: Secret?
        do {
            initial = try store.secret(for: account)
        } catch let error as CredentialStoreError where error.status == errSecMissingEntitlement {
            #if os(iOS)
            throw XCTSkip("The iOS keychain needs an entitled test host; unhosted simulator tests have none (\(error))")
            #else
            throw error
            #endif
        }
        XCTAssertNil(initial)
        try store.save(Secret("first pass word"), for: account)
        try store.save(Secret(" second-pass word "), for: account)
        let read = try XCTUnwrap(try store.secret(for: account))
        read.withValue { XCTAssertEqual($0, " second-pass word ", "stored exactly, spaces included") }
        XCTAssertEqual("\(read)", Redaction.placeholder)

        try store.delete(for: account)
        XCTAssertNil(try store.secret(for: account))
        XCTAssertNoThrow(try store.delete(for: account), "removing twice is fine")
    }
}
