import XCTest
import MailAccounts
import MailCore
import MailProvider
import MailStore
import MailSync

/// Everyday actions through the app model (GKM-015): which folder each action moves a message
/// out of and into, Undo and Redo through the window's undo manager, and — with the local test
/// mail server — that an action reaches the provider. A real store in a temporary folder; no fakes.
@MainActor
final class MailActionsTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var credentials: KeychainCredentialStore!
    private let work = MailAccountID("work")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gitmail-actions-\(UUID().uuidString)", isDirectory: true)
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

    /// An account as the sync left it, without a connection on this Mac: its folders and three
    /// inbox messages, two of them one conversation.
    private func seed(folders: [SyncedFolder]) async throws {
        let store = try await MailStore.open(locations)
        try await store.save(MailAccount(id: work, displayName: "Work", address: "ada@example.com"))
        try await store.replaceSyncedFolders(folders, account: work)
        let messages = [
            ("Plan", "Tue, 24 Nov 2026 09:00:00 +0000", "plan@example.com", nil as String?),
            ("Re: Plan", "Tue, 24 Nov 2026 10:00:00 +0000", "re-plan@example.com", "plan@example.com"),
            ("Lunch", "Mon, 23 Nov 2026 12:00:00 +0000", "lunch@example.com", nil),
        ]
        for (uid, message) in messages.enumerated() {
            var headers = "From: Bo <bo@example.net>\r\nTo: ada@example.com\r\nSubject: \(message.0)\r\nDate: \(message.1)\r\nMessage-ID: <\(message.2)>\r\n"
            if let parent = message.3 { headers += "In-Reply-To: <\(parent)>\r\n" }
            let result = try await store.ingest(Data((headers + "\r\nBody.\r\n").utf8), account: work,
                                                remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: UInt32(uid + 1)))
            try await store.setFlags([result.id: MailMessageFlags()], account: work)
        }
    }

    private func undoManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    private func subjects(_ model: AppModel) -> [String] { model.browser.rows.compactMap(\.latest.subject).sorted() }

    private func threads(_ model: AppModel, _ subject: String) -> [String] {
        model.browser.rows.filter { $0.latest.subject == subject }.map(\.threadID)
    }

    // MARK: - Without a server

    func testArchiveMovesWholeConversationsOutOfTheInboxAndUndoRedoWork() async throws {
        try await seed(folders: [SyncedFolder(name: "INBOX", path: ["INBOX"], role: "inbox"),
                                 SyncedFolder(name: "Archive", path: ["Archive"], role: "archive")])
        let model = AppModel(locations: locations, services: services())
        await model.open()
        let undo = undoManager()
        model.actions.undoManager = undo
        await model.select(.folder(work, "INBOX"))
        XCTAssertEqual(subjects(model), ["Lunch", "Re: Plan"])

        await model.actions.perform(.archive, threads: threads(model, "Re: Plan"), in: model.browser.scope)
        XCTAssertEqual(subjects(model), ["Lunch"], "both messages of the conversation left the inbox")
        await model.select(.folder(work, "Archive"))
        XCTAssertEqual(subjects(model), ["Re: Plan"])
        let store = try XCTUnwrap(model.mailStore)
        let pending = try await store.actionStatus(account: work).pending
        XCTAssertEqual(pending, 2, "queued for the provider")
        XCTAssertEqual(undo.undoActionName, "Archive")

        undo.undo()
        await model.actions.waitForUndo()
        XCTAssertEqual(subjects(model), [])
        await model.select(.folder(work, "INBOX"))
        XCTAssertEqual(subjects(model), ["Lunch", "Re: Plan"])
        XCTAssertTrue(undo.canRedo)

        undo.redo()
        await model.actions.waitForUndo()
        await model.browser.reload()
        XCTAssertEqual(subjects(model), ["Lunch"], "Redo archives again")
    }

    func testReadFlagAndTrashActOnTheMarkedConversations() async throws {
        try await seed(folders: [SyncedFolder(name: "INBOX", path: ["INBOX"], role: "inbox"),
                                 SyncedFolder(name: "Deleted Messages", path: ["Deleted Messages"], role: "trash")])
        let model = AppModel(locations: locations, services: services())
        await model.open()
        let undo = undoManager()
        model.actions.undoManager = undo
        let all = model.browser.rows.map(\.threadID)
        XCTAssertEqual(all.count, 2)

        await model.actions.perform(.markRead, threads: all, in: model.browser.scope)
        XCTAssertTrue(model.browser.rows.allSatisfy { !$0.isUnread })
        await model.actions.perform(.flag, threads: threads(model, "Re: Plan"), in: model.browser.scope)
        XCTAssertEqual(model.browser.rows.filter(\.isFlagged).compactMap(\.latest.subject), ["Re: Plan"])

        // From All Mail, Trash takes a message out of every folder it is in, into the account's Trash.
        await model.actions.perform(.moveToTrash, threads: threads(model, "Lunch"), in: model.browser.scope)
        await model.select(.folder(work, "Deleted Messages"))
        XCTAssertEqual(subjects(model), ["Lunch"])
        XCTAssertTrue(model.actions.isTrash(model.browser.scope))

        // In Trash, Delete Permanently asks first.
        await model.actions.requestDeletion(threads: threads(model, "Lunch"), in: model.browser.scope)
        XCTAssertEqual(model.actions.deletionToConfirm?.count, 1)
        await model.actions.confirmDeletion()
        XCTAssertEqual(subjects(model), [])
        let store = try XCTUnwrap(model.mailStore)
        let lunch = try await store.search("Lunch", account: work).first?.id
        XCTAssertNotNil(lunch, "the message stays in the mail folder (MAIL-029)")

        // Undo, step by step: back in Trash, back in the inbox, unflagged, unread.
        undo.undo(); await model.actions.waitForUndo()
        XCTAssertEqual(subjects(model), ["Lunch"])
        undo.undo(); await model.actions.waitForUndo()
        undo.undo(); await model.actions.waitForUndo()
        undo.undo(); await model.actions.waitForUndo()
        await model.select(.folder(work, "INBOX"))
        XCTAssertEqual(subjects(model), ["Lunch", "Re: Plan"])
        XCTAssertTrue(model.browser.rows.allSatisfy(\.isUnread))
        XCTAssertFalse(model.browser.rows.contains(where: \.isFlagged))
    }

    func testArchiveUsesAllMailWithoutAnArchiveFolderAndCreatesOneOtherwise() async throws {
        try await seed(folders: [SyncedFolder(name: "INBOX", path: ["INBOX"], role: "inbox"),
                                 SyncedFolder(name: "[Gmail]/All Mail", path: ["[Gmail]", "All Mail"], role: "all")])
        let model = AppModel(locations: locations, services: services())
        await model.open()
        XCTAssertEqual(model.actions.archiveFolder(for: work)?.name, "[Gmail]/All Mail")
        XCTAssertEqual(model.actions.archiveFolder(for: work)?.create, false)
        XCTAssertEqual(model.actions.trashFolder(for: work)?.name, "Trash")
        XCTAssertEqual(model.actions.trashFolder(for: work)?.create, true)

        try await model.mailStore?.replaceSyncedFolders([SyncedFolder(name: "INBOX", path: ["INBOX"], role: "inbox")], account: work)
        await model.sync.start(model.accounts, store: try XCTUnwrap(model.mailStore))
        XCTAssertEqual(model.actions.archiveFolder(for: work)?.name, "Archive")
        XCTAssertEqual(model.actions.archiveFolder(for: work)?.create, true)
        // A move to a folder of another account does nothing to these messages.
        await model.actions.perform(.move(to: "Archive", account: MailAccountID("other")), threads: model.browser.rows.map(\.threadID),
                                    in: model.browser.scope)
        let store = try XCTUnwrap(model.mailStore)
        let pending = try await store.actionStatus(account: work).pending
        XCTAssertEqual(pending, 0)
    }

    func testOpeningAMessageMarksItReadThroughTheJournal() async throws {
        try await seed(folders: [SyncedFolder(name: "INBOX", path: ["INBOX"], role: "inbox")])
        let model = AppModel(locations: locations, services: services())
        await model.open()
        let row = try XCTUnwrap(model.browser.rows.first { $0.latest.subject == "Lunch" })
        await model.browser.select(row.id)
        let store = try XCTUnwrap(model.mailStore)
        let queued = try await store.pendingActions(account: work)
        XCTAssertEqual(queued.map(\.kind), [.seen], "the reader's read mark goes to the provider too")
    }

    // MARK: - With the local test mail server

    func testAnArchiveReachesTheProviderAndItsUndoBringsItBack() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        try await server.append(["Keep", "File away"], for: user)
        let model = AppModel(locations: locations, services: services(trust: server.trust))
        await model.open()
        let undo = undoManager()
        model.actions.undoManager = undo

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
        let account = try await model.addAccount(draft)
        try await waitUntil("two messages") { model.browser.rows.count == 2 }
        try await waitUntil("the folder list") { model.sync.folders[account.id]?.isEmpty == false }

        await model.actions.perform(.archive, threads: threads(model, "File away"), in: model.browser.scope)
        try await waitUntil("the archive at the provider") { try await self.serverSubjects(server, user, "Archive") == ["File away"] }
        let inbox = try await serverSubjects(server, user, "INBOX")
        XCTAssertEqual(inbox, ["Keep"])
        try await waitUntil("the journal to empty") { model.sync.replay[account.id]?.status.pending == 0 }

        undo.undo()
        await model.actions.waitForUndo()
        try await waitUntil("the undo at the provider") { try await self.serverSubjects(server, user, "INBOX") == ["File away", "Keep"] }
        let archive = try await serverSubjects(server, user, "Archive")
        XCTAssertEqual(archive, [])
        await model.sync.stopAll()
    }

    private func serverSubjects(_ server: LocalMailServer, _ user: LocalMailServer.User, _ folder: String) async throws -> [String] {
        let settings = MailConnectionSettings(
            kind: .imap,
            imap: MailServerSettings(host: "localhost", port: server.imapsPort, security: .implicitTLS, username: user.address),
            smtp: MailServerSettings(host: "localhost", port: server.smtpsPort, security: .implicitTLS, username: user.address))
        return try await AccountConnections(trust: server.trust).imap(settings, password: Secret(user.password)).withSession { session in
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
