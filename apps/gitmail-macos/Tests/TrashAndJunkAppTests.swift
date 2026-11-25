import XCTest
import MailAccounts
import MailClassifier
import MailCore
import MailProvider
import MailStore
import MailSync

/// Mail in Trash or Junk leaves every other view (GKM-075, MAIL-102), through the app model:
/// trashed or junked from a category, All Mail or a search, it is gone from that list, the other
/// views and the counts at once, it is in Trash or Junk, and moving it back (or Undo) brings it
/// back. With the local test mail server: a message moved to Trash at the provider, by another
/// client, leaves the views after the sync. A real store in a temporary folder; no fakes.
@MainActor
final class TrashAndJunkAppTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var credentials: KeychainCredentialStore!
    private let work = MailAccountID("work")
    private let me = "ada@example.com"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm075-app-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
        defaultsSuite = "gkm075-tests-\(UUID().uuidString)"
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

    private static let folders = [
        SyncedFolder(name: "INBOX", path: ["INBOX"], role: "inbox"),
        SyncedFolder(name: "Deleted Messages", path: ["Deleted Messages"], role: "trash"),
        SyncedFolder(name: "Junk", path: ["Junk"], role: "junk"),
    ]

    private static func eml(from: String, subject: String, minutesAgo: Double, headers: [String] = []) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let lines = ["From: \(from)", "To: ada@example.com", "Subject: \(subject)",
                     "Date: \(formatter.string(from: Date(timeIntervalSinceNow: -minutesAgo * 60)))",
                     "Message-ID: <\(UUID().uuidString)@example.net>"]
            + headers + ["MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8", "", "\(subject) body.", ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private static let newsletterHeaders = ["List-ID: <weekly.news.example.org>", "List-Unsubscribe: <https://news.example.org/u>"]

    /// An account as the sync left it: a person's message in Focused and three newsletters in
    /// Subscriptions, all unread in the inbox, classified as they arrived.
    private func openSeeded() async throws -> AppModel {
        let store = try await MailStore.open(locations)
        try await store.save(MailAccount(id: work, displayName: "Work", address: me))
        try await store.replaceSyncedFolders(Self.folders, account: work)
        let messages: [(String, String, [String])] = [
            ("Jo Lee <jo.lee@example.org>", "Dinner on Friday", []),
            ("The Weekly <news@news.example.org>", "Weekly newsletter: autumn walks", Self.newsletterHeaders),
            ("The Weekly <news@news.example.org>", "Weekly newsletter: winter coats", Self.newsletterHeaders),
            ("The Weekly <news@news.example.org>", "Weekly newsletter: spring seeds", Self.newsletterHeaders),
        ]
        for (uid, message) in messages.enumerated() {
            let id = try await store.ingest(Self.eml(from: message.0, subject: message.1, minutesAgo: Double(10 * (uid + 1)), headers: message.2),
                                            account: work, remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: UInt32(uid + 1))).id
            try await store.setFlags([id: MailMessageFlags()], account: work)
        }
        let model = AppModel(locations: locations, services: services())
        await model.open()
        await model.attention.waitForClassification()
        let newsletters = try await XCTUnwrap(model.mailStore).threads(SearchQuery(category: .subscriptions)).count
        XCTAssertEqual(newsletters, 3, "the newsletters are in Subscriptions")
        return model
    }

    private func undoManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    private func subjects(_ model: AppModel) -> [String] { model.browser.rows.compactMap(\.latest.subject).sorted() }

    private func rows(_ model: AppModel, containing word: String) -> [ListRow] {
        model.browser.rows.filter { $0.latest.subject?.contains(word) == true }
    }

    /// Subjects a sidebar entry shows, read through the browser the way the window does.
    private func shown(_ model: AppModel, in selection: SidebarSelection) async -> [String] {
        await model.select(selection)
        return subjects(model)
    }

    private let allSubjects = ["Dinner on Friday", "Weekly newsletter: autumn walks", "Weekly newsletter: spring seeds",
                               "Weekly newsletter: winter coats"]

    // MARK: - Without a server

    func testTrashFromSubscriptionsLeavesEveryViewAndTheCountsAtOnceAndUndoBringsItBack() async throws {
        let model = try await openSeeded()
        let undo = undoManager()
        model.actions.undoManager = undo
        await model.select(.category(.subscriptions))
        XCTAssertEqual(subjects(model).count, 3)
        XCTAssertEqual(model.attention.count(.subscriptions).total, 3)
        let focusedBefore = model.attention.count(.focused)
        let walks = try XCTUnwrap(rows(model, containing: "autumn").first)

        await model.actions.perform(.moveToTrash, threads: [walks.threadID], in: model.browser.scope)

        XCTAssertEqual(subjects(model), ["Weekly newsletter: spring seeds", "Weekly newsletter: winter coats"],
                       "gone from the list it was trashed from, at once")
        XCTAssertEqual(model.attention.count(.subscriptions).total, 2, "and from the counts, without waiting for a sync")
        XCTAssertEqual(model.attention.count(.subscriptions).unread, 2)
        XCTAssertEqual(model.attention.count(.focused), focusedBefore)
        let allMail = await shown(model, in: .allMail)
        XCTAssertEqual(allMail, allSubjects.filter { !$0.contains("autumn") })
        let account = await shown(model, in: .account(work))
        XCTAssertEqual(account, allSubjects.filter { !$0.contains("autumn") })
        let focused = await shown(model, in: .category(.focused))
        XCTAssertFalse(focused.contains { $0.contains("autumn") })
        let trash = await shown(model, in: .folder(work, "Deleted Messages"))
        XCTAssertEqual(trash, ["Weekly newsletter: autumn walks"], "it is in Trash")

        // Undo brings it back everywhere.
        undo.undo()
        await model.actions.waitForUndo()
        let trashAfterUndo = subjects(model)
        XCTAssertEqual(trashAfterUndo, [])
        let subscriptions = await shown(model, in: .category(.subscriptions))
        XCTAssertEqual(subscriptions.count, 3)
        XCTAssertEqual(model.attention.count(.subscriptions).total, 3)

        // Trash it again, then move it back out of Trash by hand: back in Subscriptions.
        let again = try XCTUnwrap(rows(model, containing: "autumn").first)
        await model.actions.perform(.moveToTrash, threads: [again.threadID], in: model.browser.scope)
        XCTAssertEqual(subjects(model).count, 2)
        await model.select(.folder(work, "Deleted Messages"))
        await model.actions.perform(.move(to: "INBOX", account: work), threads: model.browser.rows.map(\.threadID), in: model.browser.scope)
        XCTAssertEqual(subjects(model), [], "out of Trash")
        let restored = await shown(model, in: .category(.subscriptions))
        XCTAssertEqual(restored.count, 3)
        XCTAssertEqual(model.attention.count(.subscriptions).total, 3)
        let allAgain = await shown(model, in: .allMail)
        XCTAssertEqual(allAgain, allSubjects)
    }

    func testJunkFromAllMailLeavesTheViewsAndMovingItBackRestoresIt() async throws {
        let model = try await openSeeded()
        await model.select(.allMail)
        let coats = try XCTUnwrap(rows(model, containing: "winter").first)
        await model.actions.perform(.move(to: "Junk", account: work), threads: [coats.threadID], in: model.browser.scope)

        XCTAssertEqual(subjects(model), allSubjects.filter { !$0.contains("winter") }, "gone from All Mail at once")
        XCTAssertEqual(model.attention.count(.subscriptions).total, 2)
        let subscriptions = await shown(model, in: .category(.subscriptions))
        XCTAssertEqual(subscriptions.count, 2)
        let junk = await shown(model, in: .folder(work, "Junk"))
        XCTAssertEqual(junk, ["Weekly newsletter: winter coats"])

        await model.actions.perform(.move(to: "INBOX", account: work), threads: model.browser.rows.map(\.threadID), in: model.browser.scope)
        XCTAssertEqual(subjects(model), [])
        let back = await shown(model, in: .category(.subscriptions))
        XCTAssertEqual(back.count, 3)
        XCTAssertEqual(model.attention.count(.subscriptions).total, 3)
    }

    /// Sil: "I selected multiple and then did delete, then they should disappear, maybe show in
    /// the trash then, but not in my selections."
    func testDeletingSeveralFromAFilteredSearchTakesThemOutOfThatListAtOnce() async throws {
        let model = try await openSeeded()
        let undo = undoManager()
        model.actions.undoManager = undo
        await model.select(.category(.subscriptions))
        await model.browser.setFilters(SearchFilters(unreadOnly: true))
        await model.browser.search("newsletter")
        XCTAssertEqual(subjects(model).count, 3)
        let seeds = try XCTUnwrap(rows(model, containing: "spring").first), coats = try XCTUnwrap(rows(model, containing: "winter").first)
        await model.browser.select(seeds.id)
        model.browser.toggleMark(coats.id)
        XCTAssertEqual(model.browser.markedRowIDs, [seeds.id, coats.id])

        let marked = model.browser.threadIDs(actingOn: nil)
        await model.actions.perform(.moveToTrash, threads: marked, in: model.browser.scope)

        XCTAssertEqual(subjects(model), ["Weekly newsletter: autumn walks"], "gone from the same filtered search at once")
        XCTAssertEqual(model.browser.markedRowIDs, [], "and from the marks")
        XCTAssertNil(model.browser.selectedRowID)
        XCTAssertEqual(model.attention.count(.subscriptions).total, 1)
        // In Trash, also when searched there.
        await model.select(.folder(work, "Deleted Messages"))
        await model.browser.clearSearch()
        XCTAssertEqual(subjects(model), ["Weekly newsletter: spring seeds", "Weekly newsletter: winter coats"])
        await model.browser.search("newsletter")
        XCTAssertEqual(subjects(model).count, 2, "searching inside Trash finds them")

        // Undo brings them back into the search.
        await model.select(.category(.subscriptions))
        await model.browser.search("newsletter")
        XCTAssertEqual(subjects(model).count, 1)
        undo.undo()
        await model.actions.waitForUndo()
        XCTAssertEqual(subjects(model).count, 3)
        XCTAssertEqual(model.attention.count(.subscriptions).total, 3)
    }

    func testSpacesCountsFollowATrashAtOnce() async throws {
        let model = try await openSeeded()
        await model.select(.allMail)
        let dinner = try XCTUnwrap(rows(model, containing: "Dinner").first)
        let created = await model.spaces.create(name: "Friends", icon: SpaceAppearance.defaultIcon, color: SpaceAppearance.defaultColor)
        let space = try XCTUnwrap(created)
        await model.spaces.add(threads: [dinner.threadID], to: space.id)
        XCTAssertEqual(model.spaces.counts[space.id]?.messages, 1)

        await model.actions.perform(.moveToTrash, threads: [dinner.threadID], in: model.browser.scope)
        XCTAssertEqual(model.spaces.counts[space.id]?.messages ?? 0, 0)
        let inSpace = await shown(model, in: .space(space.id))
        XCTAssertEqual(inSpace, [])
    }

    // MARK: - With the local test mail server

    func testAMessageMovedToTrashAtTheProviderLeavesTheViewsAfterTheSync() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        try await server.append(["Keep", "Throw away"], for: user)
        let settings = MailConnectionSettings(
            kind: .imap,
            imap: MailServerSettings(host: "localhost", port: server.imapsPort, security: .implicitTLS, username: user.address),
            smtp: MailServerSettings(host: "localhost", port: server.smtpsPort, security: .implicitTLS, username: user.address))
        let other = AccountConnections(trust: server.trust)
        // Another client made the account's Trash before this app ever saw the account.
        try await other.imap(settings, password: Secret(user.password)).withSession { session in
            try await session.createFolder("Trash")
        }
        let model = AppModel(locations: locations, services: services(trust: server.trust))
        await model.open()
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
        try await waitUntil("the folder list") { model.sync.folders[account.id]?.contains { $0.name == "Trash" } == true }
        XCTAssertEqual(model.sync.folders[account.id]?.first { $0.name == "Trash" }?.role, "trash")
        let focusedBefore = model.attention.count(.focused).total

        // The other client moves one to Trash.
        try await other.imap(settings, password: Secret(user.password)).withSession { session in
            let listing = try await session.listing(of: "INBOX")
            let ids = listing.uids.map { RemoteMessageID(folder: "INBOX", uidValidity: listing.status.uidValidity, uid: $0) }
            let summaries = try await session.summaries(of: ids)
            let target = try XCTUnwrap(summaries.first { $0.subject == "Throw away" }?.id)
            _ = try await session.move([target], to: "Trash")
        }
        await model.sync.syncNow()
        try await waitUntil("the move to arrive") {
            try await model.mailStore?.threads(SearchQuery(account: account.id, mailbox: "Trash")).count == 1
        }
        // The app refreshes its list and counts when the sync stored the change; nothing here reloads.
        try await waitUntil("All Mail and the counts to follow the sync") {
            self.subjects(model) == ["Keep"] && model.attention.count(.focused).total == focusedBefore - 1
        }
        let focused = await shown(model, in: .category(.focused))
        XCTAssertEqual(focused, ["Keep"])
        let trash = await shown(model, in: .folder(account.id, "Trash"))
        XCTAssertEqual(trash, ["Throw away"])
        await model.sync.stopAll()
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(30), _ condition: () async throws -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now + timeout
        while clock.now < end {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("timed out waiting for \(what)")
    }
}
