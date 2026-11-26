import XCTest
import MailAccounts
import MailCore
import MailProvider
import MailStore
import MailSync

/// "See All Mail from…", Select All and acting on many at once (GKM-071, MAIL-098..100), through
/// the app model with a real store; with the local test mail server, that deleting hundreds
/// from one sender reaches the provider and one Undo brings them back. No fakes.
@MainActor
final class SelectionAppTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var credentials: KeychainCredentialStore!
    private let work = MailAccountID("work")
    private let home = MailAccountID("home")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm071-selection-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
        defaultsSuite = "gkm071-tests-\(UUID().uuidString)"
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
        let connections = AccountConnections(trust: trust, connectTimeout: .seconds(5), commandTimeout: .seconds(30))
        return AccountServices(
            credentials: credentials, connections: connections, verifier: AccountVerifier(connections: connections),
            syncOptions: SyncOptions(idleTimeout: .seconds(30),
                                     reconnect: ReconnectPolicy(initialDelay: .milliseconds(50), maxDelay: .milliseconds(200), jitter: 0)),
            defaults: defaults)
    }

    private func undoManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    private static let folders = [SyncedFolder(name: "INBOX", path: ["INBOX"], role: "inbox"),
                                  SyncedFolder(name: "Archive", path: ["Archive"], role: "archive"),
                                  SyncedFolder(name: "Sent", path: ["Sent"], role: "sent"),
                                  SyncedFolder(name: "Trash", path: ["Trash"], role: "trash")]

    private struct Mail {
        var account: MailAccountID
        var folder: String
        var from: String
        var subject: String
        var id: String
        var to = "ada@example.com"
        var parent: String?
    }

    private func seed(_ mail: [Mail]) async throws {
        let store = try await MailStore.open(locations)
        for account in Set(mail.map(\.account)) {
            try await store.save(MailAccount(id: account, displayName: account.rawValue.capitalized, address: "ada@example.com"))
            try await store.replaceSyncedFolders(Self.folders, account: account)
        }
        for (n, message) in mail.enumerated() {
            let minute = n % 60, hour = n / 60 % 24, day = 1 + n / 1440
            var headers = "From: \(message.from)\r\nTo: \(message.to)\r\nSubject: \(message.subject)\r\n"
            headers += String(format: "Date: %02d Nov 2026 %02d:%02d:00 +0000\r\n", day, hour, minute)
            headers += "Message-ID: <\(message.id)>\r\n"
            if let parent = message.parent { headers += "In-Reply-To: <\(parent)>\r\n" }
            let result = try await store.ingest(Data((headers + "\r\nBody.\r\n").utf8), account: message.account,
                                                remote: RemoteLocation(mailbox: message.folder, uidValidity: 1, uid: UInt32(n + 1)))
            try await store.setFlags([result.id: MailMessageFlags()], account: message.account)
        }
    }

    private func subjects(_ model: AppModel) -> [String] { model.browser.rows.compactMap(\.latest.subject).sorted() }

    // MARK: - See All Mail from…

    func testSeeAllMailFromIsExactlyThatSenderAcrossAccountsAndFoldersAndEscapeGoesBack() async throws {
        try await seed([
            Mail(account: work, folder: "INBOX", from: "Deals <deals@shop.example>", subject: "Sale one", id: "s1@x"),
            Mail(account: work, folder: "Archive", from: "DEALS@SHOP.EXAMPLE", subject: "Sale two", id: "s2@x"),
            Mail(account: home, folder: "INBOX", from: "Deals <deals@shop.example>", subject: "Sale three", id: "s3@x"),
            Mail(account: work, folder: "INBOX", from: "Hot <hot-deals@shop.example>", subject: "Not them", id: "o1@x"),
            Mail(account: work, folder: "Sent", from: "Ada <ada@example.com>", subject: "Re: Sale one", id: "r1@x",
                 to: "deals@shop.example", parent: "s1@x"),
        ])
        let model = AppModel(locations: locations, services: services())
        await model.open()
        await model.select(.folder(work, "INBOX"))
        let row = try XCTUnwrap(model.browser.rows.first { $0.latest.subject == "Sale one" || $0.latest.subject == "Re: Sale one" })
        let sender = MailAddress(name: "Deals", address: "deals@shop.example")
        XCTAssertEqual(row.latest.from?.address, "deals@shop.example")

        await model.showAllMail(from: sender)
        XCTAssertEqual(model.selection, .allMail)
        XCTAssertEqual(model.browser.filters.sender, sender, "the From chip")
        XCTAssertEqual(model.browser.searchText, "")
        XCTAssertEqual(subjects(model), ["Sale one", "Sale three", "Sale two"],
                       "every account and folder, any case; never mail to them or from a longer address")
        XCTAssertEqual(SenderText.name(sender), "Deals")

        // Deleting all of it takes those messages, not the reply you wrote in the same conversation.
        await model.browser.selectAll()
        XCTAssertEqual(model.browser.selectionTitle, "3 messages selected")
        await model.actions.trash(model.browser.targets(actingOn: nil), in: model.browser.scope)
        XCTAssertNil(model.actions.trashToConfirm, "three do not ask")
        let store = try XCTUnwrap(model.mailStore)
        let replies = try await store.search(SearchQuery(mailbox: "Sent"))
        let reply = try XCTUnwrap(replies.first { $0.subject == "Re: Sale one" })
        let replyBoxes = try await store.effectiveMailboxes(of: reply.id)
        XCTAssertEqual(replyBoxes, ["Sent"], "your reply stays where it was")
        let trashed = try await store.search(SearchQuery(mailbox: "Trash")).compactMap(\.subject).sorted()
        XCTAssertEqual(trashed, ["Sale one", "Sale three", "Sale two"])
        XCTAssertTrue(model.browser.markedRowIDs.isEmpty, "the selection ends with the move")

        // Escape (or the chip's close) goes back to where it started.
        await model.leaveSenderView()
        XCTAssertNil(model.browser.filters.sender)
        XCTAssertEqual(model.selection, .folder(work, "INBOX"))
        XCTAssertEqual(subjects(model), ["Not them"])
    }

    // MARK: - Select All, many pages, one Undo

    func testSelectAllTakesEveryRowNotOnlyTheLoadedPageAndOneUndoBringsThemBack() async throws {
        let count = MailBrowser.pageSize + 60
        var mail = (0..<count).map { Mail(account: work, folder: "INBOX", from: "News <news@list.example>", subject: "Issue \($0)", id: "n\($0)@x") }
        mail.append(Mail(account: work, folder: "INBOX", from: "Bo <bo@example.net>", subject: "Lunch", id: "l@x"))
        try await seed(mail)
        let model = AppModel(locations: locations, services: services())
        await model.open()
        let undo = undoManager()
        model.actions.undoManager = undo

        await model.showAllMail(from: MailAddress(name: "News", address: "news@list.example"))
        XCTAssertEqual(model.browser.rows.count, MailBrowser.pageSize, "one page loaded")
        XCTAssertTrue(model.browser.canLoadMore)
        await model.browser.selectAll()
        XCTAssertEqual(model.browser.markedRowIDs.count, count, "every match, loaded or not")
        XCTAssertEqual(model.browser.rows.count, MailBrowser.pageSize, "and no more rows were loaded for it")
        XCTAssertEqual(model.browser.selectionTitle, "\(count) messages selected")
        XCTAssertTrue(model.browser.selectsMany)

        // ⌘-click a loaded row: an exception to the selection.
        let first = try XCTUnwrap(model.browser.rows.first)
        model.browser.toggleMark(first.id)
        let targets = model.browser.targets(actingOn: nil)
        XCTAssertEqual(targets.count, count - 1)

        // Many ask once, then go in one step: one journal batch, one Undo.
        await model.actions.trash(targets, in: model.browser.scope)
        let shown = try XCTUnwrap(model.actions.trashToConfirm)
        XCTAssertEqual(shown.question, "Move \(count - 1) messages to Trash?")
        // As the dialog does it: closing clears the request before the button's task runs.
        model.actions.trashToConfirm = nil
        await model.actions.confirmTrash(shown)
        XCTAssertTrue(model.browser.markedRowIDs.isEmpty)
        let store = try XCTUnwrap(model.mailStore)
        let pending = try await store.actionStatus(account: work).pending
        XCTAssertEqual(pending, count - 1, "one move each, queued for the provider")
        XCTAssertEqual(undo.undoActionName, "Move to Trash")
        var inbox = try await store.search(SearchQuery(mailbox: "INBOX"), limit: 1000).compactMap(\.subject)
        XCTAssertEqual(Set(inbox), ["Lunch", first.latest.subject!], "the exception stayed")

        undo.undo()
        await model.actions.waitForUndo()
        XCTAssertFalse(undo.canUndo, "one Undo for all of them")
        inbox = try await store.search(SearchQuery(mailbox: "INBOX"), limit: 1000).compactMap(\.subject)
        XCTAssertEqual(inbox.count, count + 1)
        let unsent = try await store.actionStatus(account: work).pending
        XCTAssertEqual(unsent, 2 * (count - 1), "each move and its Undo, both unsent: the replay settles them without sending (MAIL-037)")
    }

    func testTheSelectionBelongsToItsViewAndRowsThatLeaveGoWithoutMovingTheList() async throws {
        let count = MailBrowser.pageSize + 60
        try await seed((0..<count).map { Mail(account: work, folder: "INBOX", from: "Bo <bo@example.net>", subject: "Note \($0)", id: "b\($0)@x") })
        let model = AppModel(locations: locations, services: services())
        await model.open()
        await model.select(.folder(work, "INBOX"))
        await model.browser.selectAll()
        XCTAssertEqual(model.browser.selectionTitle, "\(count) conversations selected")
        await model.browser.search("note")
        XCTAssertTrue(model.browser.markedRowIDs.isEmpty, "a new search ends the selection")
        await model.browser.clearSearch()

        // Scrolled down: everything is loaded. Three rows archived leave at once, the rest stay loaded.
        await model.browser.loadMore()
        XCTAssertEqual(model.browser.rows.count, count)
        for row in model.browser.rows.suffix(3) { model.browser.toggleMark(row.id) }
        await model.actions.perform(.archive, targets: model.browser.targets(actingOn: nil), in: model.browser.scope)
        XCTAssertEqual(model.browser.rows.count, count - 3, "gone from the list, and the list did not go back to its first page")
        XCTAssertTrue(model.browser.markedRowIDs.isEmpty)
        // Flagging keeps the selection: the rows stay.
        for row in model.browser.rows.prefix(2) { model.browser.toggleMark(row.id) }
        await model.actions.perform(.flag, targets: model.browser.targets(actingOn: nil), in: model.browser.scope)
        XCTAssertEqual(model.browser.markedRowIDs.count, 2)
        XCTAssertEqual(model.browser.rows.prefix(2).filter(\.isFlagged).count, 2)
    }

    // MARK: - With the local test mail server

    func testDeletingEverythingFromASenderReachesTheProviderAndOneUndoBringsItBack() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        let count = 320
        try await server.append((0..<count).map { "Deal \($0)" }, for: user, from: "Deals <deals@shop.example>")
        try await server.append(["Keep me", "And me"], for: user)
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
        let store = try XCTUnwrap(model.mailStore)
        try await waitUntil("every message stored") { try await store.messageCount() == count + 2 }
        try await waitUntil("the folder list") { model.sync.folders[account.id]?.isEmpty == false }

        await model.showAllMail(from: MailAddress(name: "Deals", address: "deals@shop.example"))
        await model.browser.selectAll()
        XCTAssertEqual(model.browser.markedRowIDs.count, count)
        await model.actions.trash(model.browser.targets(actingOn: nil), in: model.browser.scope)
        XCTAssertEqual(model.actions.trashToConfirm?.question, "Move \(count) messages to Trash?")
        await model.actions.confirmTrash()

        try await waitUntil("all of them in Trash at the provider", timeout: .seconds(180)) {
            try await self.serverSubjects(server, user, "Trash").count == count
        }
        let inbox = try await serverSubjects(server, user, "INBOX")
        XCTAssertEqual(inbox, ["And me", "Keep me"])
        try await waitUntil("the journal to empty", timeout: .seconds(60)) { model.sync.replay[account.id]?.status.pending == 0 }

        undo.undo()
        await model.actions.waitForUndo()
        try await waitUntil("the Undo at the provider", timeout: .seconds(180)) {
            try await self.serverSubjects(server, user, "INBOX").count == count + 2
        }
        let trash = try await serverSubjects(server, user, "Trash")
        XCTAssertEqual(trash, [])
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

    private func waitUntil(_ what: String, timeout: Duration = .seconds(60), _ condition: () async throws -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now + timeout
        while clock.now < end {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("timed out waiting for \(what)")
    }
}
