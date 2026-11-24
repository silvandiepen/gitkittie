import XCTest
import MailAccounts
import MailCore
import MailOutbox
import MailProvider
import MailStore
import MailSync

/// Adding, verifying, syncing and removing accounts through the app model (GKM-010, GKM-011),
/// against a real store in a temporary folder, the real Keychain (a test-only service in the
/// login keychain, removed afterwards) and, where a server is needed, the local test mail
/// server (`swift/GitKittieMailProviders/scripts/test-mail-server.sh start`). Without the
/// server those tests skip.
@MainActor
final class AccountTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var credentials: KeychainCredentialStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gitmail-accounts-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
        defaultsSuite = "gitmail-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        credentials = KeychainCredentialStore(service: "app.hakobs.gitmail.tests.\(UUID().uuidString)", useDataProtectionKeychain: false)
    }

    override func tearDown() async throws {
        if let locations, let store = try? await MailStore.open(locations) {
            for account in (try? await store.accounts()) ?? [] { try? credentials.delete(for: account.id) }
        }
        defaults?.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }

    private func services(trust: TrustPolicy) -> AccountServices {
        let connections = AccountConnections(trust: trust, connectTimeout: .seconds(5), commandTimeout: .seconds(15))
        return AccountServices(
            credentials: credentials, connections: connections, verifier: AccountVerifier(connections: connections),
            syncOptions: SyncOptions(idleTimeout: .seconds(30),
                                     reconnect: ReconnectPolicy(initialDelay: .milliseconds(50), maxDelay: .milliseconds(200), jitter: 0)),
            defaults: defaults)
    }

    private func draft(_ server: LocalMailServer, _ user: LocalMailServer.User, password: String? = nil) -> AccountDraft {
        var draft = AccountDraft()
        draft.provider = .other
        draft.address = user.address
        draft.password = password ?? user.password
        draft.imapHost = "localhost"
        draft.imapPort = server.imapsPort
        draft.smtpHost = "localhost"
        draft.smtpPort = server.smtpsPort
        draft.smtpSecurity = .implicitTLS
        draft.name = "Test"
        return draft
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(20), _ condition: () async throws -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now + timeout
        while clock.now < end {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// The setup error `body` throws, or nil when it succeeds.
    private func setupError(_ body: () async throws -> Void) async -> AccountSetupError? {
        do {
            try await body()
            return nil
        } catch {
            guard let setup = error as? AccountSetupError else {
                XCTFail("not a setup error: \(error)")
                return nil
            }
            return setup
        }
    }

    nonisolated private static func files(in folders: [URL]) -> [URL] {
        folders.flatMap { folder in
            (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        }
    }

    // MARK: - Without a server

    func testADraftSaysWhatIsMissingBeforeAnythingConnects() {
        var draft = AccountDraft()
        XCTAssertThrowsError(try draft.connection()) { XCTAssertEqual($0 as? AccountSetupError, .missingField("email address")) }
        draft.address = "not an address"
        XCTAssertThrowsError(try draft.connection()) { XCTAssertEqual($0 as? AccountSetupError, .invalidAddress) }
        draft.address = "ada@outlook.com"
        draft.password = "x"
        XCTAssertThrowsError(try draft.connection()) { XCTAssertEqual($0 as? AccountSetupError, .oauthOnly(domain: "outlook.com")) }
        draft.address = "ada@icloud.com"
        draft.password = ""
        XCTAssertThrowsError(try draft.connection()) { XCTAssertEqual($0 as? AccountSetupError, .missingField("app-specific password")) }
        draft.password = "abcd-efgh-ijkl-mnop"
        XCTAssertEqual(try draft.connection(), ProviderPresets.iCloud.connection(for: "ada@icloud.com"))
        XCTAssertEqual(draft.displayName, "iCloud")
    }

    func testOtherIMAPFillsKnownProvidersAndKeepsWhatWasTyped() throws {
        var draft = AccountDraft()
        draft.provider = .other
        draft.address = "ada@gmail.com"
        draft.suggestServers()
        XCTAssertEqual(draft.imapHost, "imap.gmail.com")
        XCTAssertEqual(draft.smtpPort, 465)
        XCTAssertEqual(draft.preset?.name, "Gmail")
        draft.password = "app password"
        XCTAssertEqual(try draft.connection().kind, .gmail)

        let before = draft
        draft.imapHost = "mail.example.net"
        draft.address = "ada@example.org"
        draft.suggestServers(previous: before)
        XCTAssertEqual(draft.imapHost, "mail.example.net", "a host the person typed is kept")
        XCTAssertNil(draft.preset)

        draft.imapHost = ""
        XCTAssertThrowsError(try draft.connection()) { XCTAssertEqual($0 as? AccountSetupError, .missingField("incoming mail server")) }
    }

    func testAChosenMailFolderGetsItsOwnDeviceState() throws {
        let standard = StoreLocations(mailFolder: root.appendingPathComponent("Documents/Mail"),
                                      deviceFolder: root.appendingPathComponent("Support/Mail"))
        let chosen = root.appendingPathComponent("Elsewhere/Mail")
        let other = root.appendingPathComponent("Other/Mail")
        let a = MailFolderLocation.locations(for: chosen, standard: standard)
        let b = MailFolderLocation.locations(for: other, standard: standard)
        XCTAssertEqual(a.mailFolder, chosen)
        XCTAssertNotEqual(a.deviceFolder, b.deviceFolder, "two folders never share an index or a mapping")
        XCTAssertEqual(a.deviceFolder, MailFolderLocation.locations(for: chosen, standard: standard).deviceFolder, "the same folder finds its state again")
        XCTAssertTrue(a.deviceFolder.path.hasPrefix(standard.deviceFolder.path))
        XCTAssertEqual(MailFolderLocation.locations(for: standard.mailFolder, standard: standard), standard)
    }

    func testAnAccountWithoutAPasswordOnThisMacAsksForOne() async throws {
        let seed = try await MailStore.open(locations)
        let connection = ProviderPresets.iCloud.connection(for: "ada@icloud.com")
        let account = MailAccount(displayName: "iCloud", address: "ada@icloud.com", connection: connection)
        try await seed.save(account)
        let model = AppModel(locations: locations, services: services(trust: .system))
        await model.open()
        XCTAssertTrue(model.needsPassword(account.id))
        XCTAssertEqual(model.syncStatus(account.id), "Password needed")
    }

    // MARK: - With the local test server

    func testAddingAnAccountVerifiesKeepsThePasswordOnlyInTheKeychainAndSyncs() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        try await server.append(["One", "Two", "Three"], for: user)
        let model = AppModel(locations: locations, services: services(trust: server.trust))
        await model.open()

        let account = try await model.addAccount(draft(server, user))
        XCTAssertEqual(model.accounts.map(\.id), [account.id])
        XCTAssertEqual(account.connection?.imap.host, "localhost")
        let saved = try XCTUnwrap(try credentials.secret(for: account.id))
        saved.withValue { XCTAssertEqual($0, user.password) }

        // The outbox can send from it, with the same Keychain item.
        let registered = await model.sending?.registry.all() ?? []
        XCTAssertEqual(registered.map(\.accountID), [account.id])
        XCTAssertEqual(registered.first?.credential.service, credentials.service)
        XCTAssertEqual(registered.first?.credential.account, account.id.rawValue)
        XCTAssertEqual(registered.first?.credential.username, user.address)

        try await waitUntil("three messages listed") { model.messages.count == 3 }
        XCTAssertEqual(Set(model.messages.compactMap(\.subject)), ["One", "Two", "Three"])
        try await waitUntil("the folder list") { model.sync.folders[account.id]?.contains { $0.name == "INBOX" } == true }
        await model.select(.folder(account.id, "INBOX"))
        XCTAssertEqual(model.messages.count, 3)
        XCTAssertEqual(model.selectedAccount?.id, account.id)

        // The password is nowhere on disk: not in account.json, not in the device state.
        for file in Self.files(in: [locations.mailFolder, locations.deviceFolder]) {
            guard let data = try? Data(contentsOf: file) else { continue }
            XCTAssertNil(data.range(of: Data(user.password.utf8)), "password found in \(file.path)")
        }

        await model.sync.stopAll()
        try await model.removeAccount(account.id, .removeMail)
        XCTAssertEqual(model.accounts, [])
        XCTAssertNil(try credentials.secret(for: account.id), "the Keychain item goes with the account")
        let afterRemoval = await model.sending?.registry.all() ?? []
        XCTAssertEqual(afterRemoval.count, 0, "and so does sending from it")
        XCTAssertEqual(model.messages, [])
        XCTAssertEqual(model.totalCount, 0)
    }

    func testAWrongPasswordAnUnreachableServerAndAnUntrustedCertificateSaveNothing() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        let model = AppModel(locations: locations, services: services(trust: server.trust))
        await model.open()

        let wrong = await setupError { try await model.addAccount(draft(server, user, password: "wrong-\(UUID())")) }
        XCTAssertEqual(wrong, .wrongPassword(.incoming, host: "localhost", kind: .imap))
        XCTAssertTrue(wrong?.message.contains("didn’t accept") == true, wrong?.message ?? "")

        var closed = draft(server, user)
        closed.imapPort = 1
        let unreachable = await setupError { try await model.addAccount(closed) }
        if case .unreachable(.incoming, "localhost", 1, _)? = unreachable {} else { XCTFail("\(String(describing: unreachable))") }
        XCTAssertTrue(unreachable?.message.hasPrefix("Couldn’t reach") == true, unreachable?.message ?? "")

        let strict = AppModel(locations: locations, services: services(trust: .system))
        await strict.open()
        let untrusted = await setupError { try await strict.addAccount(draft(server, user)) }
        if case .certificateProblem(.incoming, "localhost", _)? = untrusted {} else { XCTFail("\(String(describing: untrusted))") }
        XCTAssertTrue(untrusted?.message.contains("certificate") == true, untrusted?.message ?? "")

        XCTAssertEqual(model.accounts, [])
        let store = try await MailStore.open(locations)
        let accounts = try await store.accounts()
        XCTAssertEqual(accounts, [], "no account.json was written")
    }

    func testKeepingTheMailLeavesItReadableAndDisconnected() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        try await server.append(["Kept"], for: user)
        let model = AppModel(locations: locations, services: services(trust: server.trust))
        await model.open()
        let account = try await model.addAccount(draft(server, user))
        try await waitUntil("the message listed") { model.messages.count == 1 }

        try await model.removeAccount(account.id, .keepMail)
        XCTAssertEqual(model.accounts.map(\.id), [account.id])
        XCTAssertNil(model.accounts.first?.connection)
        XCTAssertEqual(model.syncStatus(account.id), "Not connected · mail kept on this Mac")
        XCTAssertEqual(model.messages.map(\.subject), ["Kept"])
        XCTAssertNil(try credentials.secret(for: account.id))
        XCTAssertFalse(model.sync.isSyncing(account.id))
    }

    func testExportingThenRemovingLeavesACompleteCopy() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        try await server.append(["Exported"], for: user)
        let model = AppModel(locations: locations, services: services(trust: server.trust))
        await model.open()
        let account = try await model.addAccount(draft(server, user))
        try await waitUntil("the message listed") { model.messages.count == 1 }

        let exports = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try await model.removeAccount(account.id, .exportThenRemove(exports))
        XCTAssertEqual(model.accounts, [])
        let copy = try await MailStore.open(StoreLocations(mailFolder: exports.appendingPathComponent("Test Mail"),
                                                           deviceFolder: root.appendingPathComponent("ExportState")))
        let summaries = try await copy.summaries()
        XCTAssertEqual(summaries.map(\.subject), ["Exported"])
    }

    func testARevokedPasswordAsksToSignInAgainAndANewOneResumes() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        let model = AppModel(locations: locations, services: services(trust: server.trust))
        await model.open()
        let account = try await model.addAccount(draft(server, user))

        // The provider stops accepting the saved password (an app-specific password revoked).
        await model.sync.stop(account.id)
        try credentials.save(Secret("revoked-\(UUID())"), for: account.id)
        await model.sync.start(try XCTUnwrap(model.accounts.first), store: try XCTUnwrap(model.mailStore))
        try await waitUntil("the sign-in failure") { model.needsPassword(account.id) }
        XCTAssertEqual(model.syncStatus(account.id), "Password needed")

        let refused = await setupError { try await model.updatePassword("still-wrong", for: account.id) }
        XCTAssertEqual(refused, .wrongPassword(.incoming, host: "localhost", kind: .imap), "a wrong new password is refused before it is saved")
        try await model.updatePassword(user.password, for: account.id)
        try await waitUntil("syncing again") { !model.needsPassword(account.id) && model.syncStatus(account.id) == "Up to date" }
        await model.sync.stopAll()
    }
}
