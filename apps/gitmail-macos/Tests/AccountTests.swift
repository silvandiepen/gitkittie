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

    /// GKM-011, answered by Sil (MAIL-075): mail deleted at the provider is kept and shown as
    /// "Deleted at iCloud" with when, in the list and the reader; the account's setting
    /// "Remove mail deleted elsewhere" is off until turned on and is kept in account.json.
    func testMailDeletedAtTheProviderIsShownAndTheRemovalSettingIsKept() async throws {
        let seed = try await MailStore.open(locations)
        let account = MailAccount(displayName: "Family", address: "ada@icloud.com",
                                  connection: ProviderPresets.iCloud.connection(for: "ada@icloud.com"))
        try await seed.save(account)
        let eml = Data("From: Bo <bo@example.net>\r\nTo: ada@icloud.com\r\nSubject: Gone\r\nMessage-ID: <gone@example.net>\r\nDate: Tue, 24 Nov 2026 09:00:00 +0000\r\n\r\nBye\r\n".utf8)
        let location = RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 1)
        let id = try await seed.ingest(eml, account: account.id, remote: location).id
        let noticed = Date(timeIntervalSince1970: 1_795_600_000) // 2026-11-25 07:46:40 UTC
        try await seed.forget(location, account: account.id, now: noticed)
        try await seed.confirmDeletions(seed.deletionCandidates(account: account.id), account: account.id)

        let model = AppModel(locations: locations, services: services(trust: .system))
        await model.open()
        await model.select(.allMail)
        let row = try XCTUnwrap(model.browser.rows.first { $0.latest.id == id })
        XCTAssertEqual(row.latest.deletedAtProvider, noticed)
        let shown = try XCTUnwrap(model.accounts.first)
        XCTAssertEqual(ProviderDeletionText.short(row.latest, account: shown), "Deleted at iCloud", "the provider, not the account's name")
        let line = ProviderDeletionText.line(row.latest, account: shown, timeZone: TimeZone(identifier: "UTC")!,
                                             locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(line, "Deleted at iCloud · " + noticed.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened,
                                                                                         locale: Locale(identifier: "en_GB"),
                                                                                         timeZone: TimeZone(identifier: "UTC")!)))
        XCTAssertTrue(line?.contains("25 Nov 2026") == true, line ?? "")
        await model.browser.select(row.id)
        XCTAssertEqual(model.browser.openThread?.messages.last?.summary.deletedAtProvider, noticed, "the reader has it too")

        XCTAssertFalse(shown.removesDeletedMail, "off until turned on")
        try await model.updateAccountSettings(account.id, displayName: "Family", senderName: "Ada", removesMailDeletedElsewhere: true)
        let saved = try await MailStore.open(locations).accounts().first
        XCTAssertEqual(saved?.removesMailDeletedElsewhere, true)
        XCTAssertEqual(saved?.senderName, "Ada")
        XCTAssertEqual(model.totalCount, 1, "turning it on removes nothing by itself; the sync does, on its next pass")
        try await model.updateAccountSettings(account.id, displayName: "Family", senderName: "Ada", removesMailDeletedElsewhere: false)
        let off = try await MailStore.open(locations).accounts().first
        XCTAssertNil(off?.removesMailDeletedElsewhere, "off is the default again, not written out")
    }

    /// The Mac's history window (GKM-060): saved, applied to the next sync, 0 or unset is all.
    func testTheHistoryWindowIsSavedAndAppliedToTheSync() async throws {
        XCTAssertNil(AccountServices.historyDays(in: defaults), "unset downloads all of it")
        let model = AppModel(locations: locations, services: services(trust: .system))
        await model.open()
        XCTAssertNil(model.historyDays)

        await model.setHistoryDays(90)
        XCTAssertEqual(model.historyDays, 90)
        XCTAssertEqual(model.sync.services.syncOptions.historyDays, 90)
        XCTAssertEqual(AccountServices.historyDays(in: defaults), 90)

        await model.setHistoryDays(nil)
        XCTAssertNil(model.historyDays)
        XCTAssertNil(AccountServices.historyDays(in: defaults), "0 is stored for all of it")
        XCTAssertEqual(model.olderNotDownloaded, 0)
    }

    // MARK: - With the local test server

    func testAddingAnAccountVerifiesKeepsThePasswordOnlyInTheKeychainAndSyncs() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        try await server.append(["One", "Two", "Three"], for: user)
        let model = AppModel(locations: locations, services: services(trust: server.trust))
        await model.open()

        var withName = draft(server, user)
        withName.senderName = " Ada Example "
        let account = try await model.addAccount(withName)
        XCTAssertEqual(model.accounts.map(\.id), [account.id])
        XCTAssertEqual(account.connection?.imap.host, "localhost")
        XCTAssertEqual(account.senderName, "Ada Example", "Your name, asked when the account is added (MAIL-074)")
        let saved = try XCTUnwrap(try credentials.secret(for: account.id))
        saved.withValue { XCTAssertEqual($0, user.password) }

        // The outbox can send from it, with the same Keychain item.
        let registered = await model.sending?.registry.all() ?? []
        XCTAssertEqual(registered.map(\.accountID), [account.id])
        XCTAssertEqual(registered.first?.credential.service, credentials.service)
        XCTAssertEqual(registered.first?.credential.account, account.id.rawValue)
        XCTAssertEqual(registered.first?.credential.username, user.address)
        XCTAssertEqual(registered.first?.identities, [MailAddress(name: "Ada Example", address: user.address)],
                       "sent as Your name, not as the account's name \"Test\"")

        try await waitUntil("three messages listed") { model.browser.rows.map(\.latest).count == 3 }
        XCTAssertEqual(Set(model.browser.rows.map(\.latest).compactMap(\.subject)), ["One", "Two", "Three"])
        try await waitUntil("the folder list") { model.sync.folders[account.id]?.contains { $0.name == "INBOX" } == true }
        await model.select(.folder(account.id, "INBOX"))
        XCTAssertEqual(model.browser.rows.map(\.latest).count, 3)
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
        XCTAssertEqual(model.browser.rows.map(\.latest), [])
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
        try await waitUntil("the message listed") { model.browser.rows.map(\.latest).count == 1 }

        try await model.removeAccount(account.id, .keepMail)
        XCTAssertEqual(model.accounts.map(\.id), [account.id])
        XCTAssertNil(model.accounts.first?.connection)
        XCTAssertEqual(model.syncStatus(account.id), "Not connected · mail kept on this Mac")
        XCTAssertEqual(model.browser.rows.map(\.latest).map(\.subject), ["Kept"])
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
        try await waitUntil("the message listed") { model.browser.rows.map(\.latest).count == 1 }

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
