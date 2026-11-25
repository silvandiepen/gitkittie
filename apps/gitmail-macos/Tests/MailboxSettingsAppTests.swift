import XCTest
import MailAccounts
import MailCore
import MailProvider
import MailStore
import MailSync

/// An account's mailboxes through the app model (GKM-066, MAIL-093..096): the sidebar follows
/// the folders chosen to show and their order, the special folders chosen by hand are what the
/// actions use, account order, and — with the local test mail server — folders that don't sync,
/// folder edits and server changes reaching the provider. A real store in a temporary folder.
@MainActor
final class MailboxSettingsAppTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var credentials: KeychainCredentialStore!
    private let work = MailAccountID("work")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gitmail-mailboxes-\(UUID().uuidString)", isDirectory: true)
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

    private func services(trust: TrustPolicy = .system) -> AccountServices {
        let connections = AccountConnections(trust: trust, connectTimeout: .seconds(5), commandTimeout: .seconds(15))
        return AccountServices(
            credentials: credentials, connections: connections, verifier: AccountVerifier(connections: connections),
            syncOptions: SyncOptions(idleTimeout: .seconds(30),
                                     reconnect: ReconnectPolicy(initialDelay: .milliseconds(50), maxDelay: .milliseconds(200), jitter: 0)),
            defaults: defaults)
    }

    // MARK: - Without a server

    func testTheSidebarFollowsTheChosenFoldersAndOrderAndActionsUseTheChosenSpecialFolders() async throws {
        let store = try await MailStore.open(locations)
        try await store.save(MailAccount(id: work, displayName: "Work", address: "ada@example.com"))
        try await store.replaceSyncedFolders([
            SyncedFolder(name: "INBOX", path: ["INBOX"], role: "inbox"),
            SyncedFolder(name: "Archive", path: ["Archive"], role: "archive"),
            SyncedFolder(name: "Saved", path: ["Saved"]),
            SyncedFolder(name: "Bin", path: ["Bin"]),
            SyncedFolder(name: "Trash", path: ["Trash"], role: "trash"),
        ], account: work)
        _ = try await store.ingest(Data("From: Bo <bo@example.net>\r\nTo: ada@example.com\r\nSubject: Plan\r\nMessage-ID: <plan@example.com>\r\n\r\nBody.\r\n".utf8),
                                   account: work, remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 1))
        let model = AppModel(locations: locations, services: services())
        await model.open()
        let account = try XCTUnwrap(model.accounts.first)
        XCTAssertEqual(model.sidebarFolders(of: account).map(\.name), ["INBOX", "Archive", "Saved", "Bin", "Trash"])

        try await model.setShows(false, folder: "Bin", account: work)
        try await model.moveFolders(fromOffsets: [2], toOffset: 0, account: work)
        let saved = try XCTUnwrap(model.accounts.first)
        XCTAssertEqual(model.sidebarFolders(of: saved).map(\.name), ["Saved", "INBOX", "Archive", "Trash"])
        XCTAssertEqual(model.settingsFolders(of: saved).map(\.name), ["Saved", "INBOX", "Archive", "Bin", "Trash"], "Settings lists every folder")
        let reread = try await store.accounts().first?.mailboxes
        XCTAssertEqual(reread?.hidden, ["Bin"], "kept in account.json")

        // Special folders chosen by hand: the actions use them at once, before any sync.
        try await model.setSpecialFolder("Saved", for: "archive", account: work)
        try await model.setSpecialFolder("Bin", for: "trash", account: work)
        XCTAssertEqual(model.actions.archiveFolder(for: work)?.name, "Saved")
        XCTAssertEqual(model.actions.trashFolder(for: work)?.name, "Bin")
        let roles = try await store.syncedFolders(account: work)
        XCTAssertEqual(roles.first { $0.name == "Archive" }?.role, nil)
        XCTAssertEqual(roles.first { $0.name == "Archive" }?.detectedRole, "archive")
        XCTAssertEqual(model.detectedFolder(for: "archive", of: try XCTUnwrap(model.accounts.first))?.name, "Archive")

        await model.select(.folder(work, "INBOX"))
        let thread = try XCTUnwrap(model.browser.rows.first?.threadID)
        await model.actions.perform(.archive, threads: [thread], in: model.browser.scope)
        await model.select(.folder(work, "Saved"))
        XCTAssertEqual(model.browser.rows.compactMap(\.latest.subject), ["Plan"], "archived into the chosen folder")

        try await model.setSpecialFolder(nil, for: "archive", account: work)
        XCTAssertEqual(model.actions.archiveFolder(for: work)?.name, "Archive", "back to the provider's")
        await model.sync.stopAll()
    }

    func testAccountsKeepTheOrderTheyWereDraggedIn() async throws {
        let store = try await MailStore.open(locations)
        for (id, name) in [("a", "Alpha"), ("b", "Beta"), ("c", "Gamma")] {
            try await store.save(MailAccount(id: MailAccountID(id), displayName: name, address: "\(id)@example.com"))
        }
        let model = AppModel(locations: locations, services: services())
        await model.open()
        XCTAssertEqual(model.accounts.map(\.displayName), ["Alpha", "Beta", "Gamma"], "by name at first")
        try await model.moveAccounts(fromOffsets: [2], toOffset: 0)
        XCTAssertEqual(model.accounts.map(\.displayName), ["Gamma", "Alpha", "Beta"])

        try await store.save(MailAccount(id: MailAccountID("d"), displayName: "Delta", address: "d@example.com"))
        let reopened = AppModel(locations: locations, services: services())
        await reopened.open()
        XCTAssertEqual(reopened.accounts.map(\.displayName), ["Gamma", "Alpha", "Beta", "Delta"], "kept; a new account follows")
    }

    func testMovingElementsMatchesAListsMove() {
        var items = ["a", "b", "c", "d"]
        items.moveElements(fromOffsets: [0, 2], toOffset: 4)
        XCTAssertEqual(items, ["b", "d", "a", "c"])
        items.moveElements(fromOffsets: [3], toOffset: 0)
        XCTAssertEqual(items, ["c", "b", "d", "a"])
        items.moveElements(fromOffsets: [1], toOffset: 2)
        XCTAssertEqual(items, ["c", "b", "d", "a"], "a move onto itself changes nothing")
    }

    // MARK: - With the local test mail server

    func testFoldersThatDontSyncFolderEditsAndChosenFoldersReachTheProvider() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        try await server.append(["Keep", "File away"], for: user)
        try await withSession(server, user) { session in
            try await session.createFolder("Quiet")
            // GreenMail 2.1.3 drops the connection that deletes a folder an earlier session left
            // selected (README): this folder makes each pass end elsewhere.
            try await session.createFolder("Zz Later")
            _ = try await session.append(self.raw("Later", to: user), to: "Zz Later", flags: MessageFlags())
        }
        let model = AppModel(locations: locations, services: services(trust: server.trust))
        await model.open()
        let account = try await model.addAccount(draft(server, user))
        try await waitUntil("three messages") { model.totalCount == 3 }
        try await waitUntil("the folder list") { model.sync.folders[account.id]?.contains { $0.name == "Quiet" } == true }

        // A folder that doesn't sync: new mail in it stays at the provider (MAIL-093).
        try await model.setSyncs(false, folder: "Quiet", account: account.id)
        try await withSession(server, user) { session in
            _ = try await session.append(self.raw("Not here", to: user), to: "Quiet", flags: MessageFlags())
        }
        let before = Date()
        await model.sync.syncNow()
        try await waitUntil("a pass after the change") { (model.sync.progress[account.id]?.lastCompletedPass ?? .distantPast) > before }
        XCTAssertEqual(model.totalCount, 3, "nothing downloaded from Quiet")

        // Create at the provider, choose it as Archive, archive into it (MAIL-094, MAIL-095).
        let filed = try await model.createFolder(named: "Filed", in: nil, account: account.id)
        let atProvider = try await serverFolders(server, user)
        XCTAssertTrue(atProvider.contains(filed))
        XCTAssertTrue(model.settingsFolders(of: try XCTUnwrap(model.accounts.first)).contains { $0.name == filed }, "listed at once")
        try await model.setSpecialFolder(filed, for: "archive", account: account.id)
        XCTAssertEqual(model.actions.archiveFolder(for: account.id)?.name, filed, "the running sync doesn't undo the choice")
        await model.select(.folder(account.id, "INBOX"))
        try await waitUntil("the inbox") { model.browser.rows.count == 2 }
        let thread = try XCTUnwrap(model.browser.rows.first { $0.latest.subject == "File away" }?.threadID)
        await model.actions.perform(.archive, threads: [thread], in: model.browser.scope)
        try await waitUntil("the archive at the provider") { try await self.serverSubjects(server, user, filed) == ["File away"] }
        try await waitUntil("the journal to empty") { model.sync.replay[account.id]?.status.pending == 0 }
        let archiveFolders = try await serverFolders(server, user)
        XCTAssertFalse(archiveFolders.contains("Archive"), "no Archive folder was made: the chosen one was used")

        // The provider doesn't report the moved message's new UID, so the sync learns where it is
        // on its next listing; only then is its copy known to be in the folder.
        let afterArchive = Date()
        await model.sync.syncNow()
        try await waitUntil("a pass after the archive") { (model.sync.progress[account.id]?.lastCompletedPass ?? .distantPast) > afterArchive }
        try await waitUntil("the archived message in the folder") {
            try await model.mailStore?.summaries(account: account.id, mailbox: filed).compactMap(\.subject) == ["File away"]
        }

        // Rename: at the provider, the choices follow, and the mail stays without downloading again.
        let folder = try XCTUnwrap(model.sync.folders[account.id]?.first { $0.name == filed })
        let kept = try await model.renameFolder(folder, to: "Kept", account: account.id)
        let renamed = try await serverFolders(server, user)
        XCTAssertTrue(renamed.contains(kept))
        XCTAssertFalse(renamed.contains(filed))
        XCTAssertEqual(model.accounts.first?.mailboxSettings.specialFolders["archive"], kept)
        XCTAssertEqual(model.actions.archiveFolder(for: account.id)?.name, kept)
        let inKept = try await model.mailStore?.summaries(account: account.id, mailbox: kept).compactMap(\.subject)
        XCTAssertEqual(inKept, ["File away"])
        try await waitUntil("a pass after the rename") { model.sync.progress[account.id]?.lastCompletedPass != nil }
        let afterRename = model.sync.progress[account.id]?.imported ?? 0
        XCTAssertEqual(afterRename, 0, "the restarted sync downloaded nothing again")

        // Delete at the provider: gone there and here, and its choices go. GreenMail 2.1.3 drops
        // a connection that deletes a folder another session left selected, and keeps that on a
        // renamed folder (the action replay last selected Kept), so the folder deleted here is
        // one no session acted in, with a folder made after it so the passes end there (README).
        let old = try await model.createFolder(named: "Old Stuff", in: nil, account: account.id)
        try await model.setShows(false, folder: old, account: account.id)
        try await withSession(server, user) { session in
            try await session.createFolder("Zzz After")
            _ = try await session.append(self.raw("After", to: user), to: "Zzz After", flags: MessageFlags())
        }
        let beforeLastPass = Date()
        await model.sync.syncNow()
        try await waitUntil("a pass with the new folder") { (model.sync.progress[account.id]?.lastCompletedPass ?? .distantPast) > beforeLastPass }
        let toDelete = try XCTUnwrap(model.sync.folders[account.id]?.first { $0.name == old })
        try await model.deleteFolder(toDelete, account: account.id)
        let afterDelete = try await serverFolders(server, user)
        XCTAssertFalse(afterDelete.contains(old))
        XCTAssertEqual(model.accounts.first?.mailboxSettings.hidden, [], "its choices go with it")
        XCTAssertFalse(model.settingsFolders(of: try XCTUnwrap(model.accounts.first)).contains { $0.name == old })
        XCTAssertEqual(model.totalCount, 4, "mail stays")
        await model.sync.stopAll()
    }

    func testServersAndPasswordAreCheckedBeforeTheyAreSaved() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        let model = AppModel(locations: locations, services: services(trust: server.trust))
        await model.open()
        let account = try await model.addAccount(draft(server, user))
        let connection = try XCTUnwrap(account.connection)

        var wrongPort = connection.imap
        wrongPort.port = server.smtpsPort // an SMTP server answers there, not IMAP
        do {
            try await model.updateServers(account.id, imap: wrongPort, smtp: connection.smtp, password: "")
            XCTFail("the incoming server is not an IMAP server")
        } catch {}
        XCTAssertEqual(model.accounts.first?.connection, connection, "nothing saved")

        var refusal: AccountSetupError?
        do {
            try await model.updateServers(account.id, imap: connection.imap, smtp: connection.smtp, password: "wrong-\(UUID().uuidString)")
        } catch {
            refusal = error
        }
        guard case .wrongPassword = refusal else { return XCTFail("a wrong password must be refused, got \(String(describing: refusal))") }
        let stillSaved = try credentials.secret(for: account.id)
        XCTAssertEqual(stillSaved.map { $0.withValue { $0 } }, user.password, "the Keychain keeps the old password")

        var renamedUser = connection.smtp
        renamedUser.username = "  \(user.address)  "
        try await model.updateServers(account.id, imap: connection.imap, smtp: renamedUser, password: user.password)
        XCTAssertEqual(model.accounts.first?.connection?.smtp.username, user.address, "trimmed, checked and saved")
        XCTAssertTrue(model.sync.isSyncing(account.id), "the sync started again")
        await model.sync.stopAll()
    }

    // MARK: - Helpers

    private func draft(_ server: LocalMailServer, _ user: LocalMailServer.User) -> AccountDraft {
        var draft = AccountDraft()
        draft.provider = .other
        draft.address = user.address
        draft.password = user.password
        draft.imapHost = "localhost"
        draft.imapPort = server.imapsPort
        draft.smtpHost = "localhost"
        draft.smtpPort = server.smtpsPort
        draft.smtpSecurity = .implicitTLS
        draft.name = "Test"
        return draft
    }

    private func raw(_ subject: String, to user: LocalMailServer.User) -> Data {
        Data("From: Bo <bo@example.net>\r\nTo: \(user.address)\r\nSubject: \(subject)\r\nMessage-ID: <\(UUID().uuidString)@example.net>\r\n\r\n\(subject) body.\r\n".utf8)
    }

    private func settings(_ server: LocalMailServer, _ user: LocalMailServer.User) -> MailConnectionSettings {
        MailConnectionSettings(
            kind: .imap,
            imap: MailServerSettings(host: "localhost", port: server.imapsPort, security: .implicitTLS, username: user.address),
            smtp: MailServerSettings(host: "localhost", port: server.smtpsPort, security: .implicitTLS, username: user.address))
    }

    private func withSession(_ server: LocalMailServer, _ user: LocalMailServer.User,
                             _ body: (any MailboxSession) async throws -> Void) async throws {
        try await AccountConnections(trust: server.trust).imap(settings(server, user), password: Secret(user.password)).withSession(body)
    }

    private func serverFolders(_ server: LocalMailServer, _ user: LocalMailServer.User) async throws -> [String] {
        try await AccountConnections(trust: server.trust).imap(settings(server, user), password: Secret(user.password)).withSession { session in
            try await session.listFolders().map(\.id)
        }
    }

    private func serverSubjects(_ server: LocalMailServer, _ user: LocalMailServer.User, _ folder: String) async throws -> [String] {
        try await AccountConnections(trust: server.trust).imap(settings(server, user), password: Secret(user.password)).withSession { session in
            guard try await session.listFolders().contains(where: { $0.id == folder }) else { return [] }
            let listing = try await session.listing(of: folder)
            guard !listing.uids.isEmpty else { return [] }
            let ids = listing.uids.map { RemoteMessageID(folder: folder, uidValidity: listing.status.uidValidity, uid: $0) }
            return try await session.summaries(of: ids).compactMap(\.subject).sorted()
        }
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
}
