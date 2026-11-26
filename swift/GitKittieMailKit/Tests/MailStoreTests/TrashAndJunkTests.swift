import XCTest
import MailCore
@testable import MailStore

/// Mail only in an account's Trash or Junk leaves every other view (GKM-075, MAIL-102): All
/// Mail, the account, the category views and their counts, spaces, senders, the cleanup
/// dashboard and search, while its own folder still shows it. A real store in a temporary
/// folder; the sync's side runs against the test server in MailSyncIntegrationTests.
final class TrashAndJunkTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let account = MailAccountID("acct-trash")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm075-trash-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let folders = [
        SyncedFolder(name: "INBOX", path: ["INBOX"], role: "inbox"),
        SyncedFolder(name: "Deleted Messages", path: ["Deleted Messages"], role: "trash"),
        SyncedFolder(name: "Spam", path: ["Spam"], role: "junk"),
        SyncedFolder(name: "Work", path: ["Work"]),
    ]

    private func location(_ mailbox: String, _ uid: UInt32) -> RemoteLocation {
        RemoteLocation(mailbox: mailbox, uidValidity: 7, uid: uid)
    }

    private func seeded(folders: [SyncedFolder] = TrashAndJunkTests.folders) async throws -> (MailStore, [String: MailMessageID]) {
        let store = try await MailStore.open(locations)
        try await store.replaceSyncedFolders(folders, account: account)
        var ids: [String: MailMessageID] = [:]
        for (uid, subject) in ["Keep", "Picnic", "Garden"].enumerated() {
            let id = try await store.ingest(SyntheticMail.plain(subject: subject, messageID: "\(subject.lowercased())@example.com", body: subject),
                                            account: account, remote: location("INBOX", UInt32(uid + 1))).id
            try await store.setFlags([id: MailMessageFlags()], account: account)
            ids[subject] = id
        }
        return (store, ids)
    }

    private func subjects(_ store: MailStore, _ query: SearchQuery) async throws -> [String] {
        try await store.threads(query).compactMap(\.latest.subject).sorted()
    }

    private func found(_ store: MailStore, _ query: SearchQuery) async throws -> [String] {
        try await store.search(query).compactMap(\.subject).sorted()
    }

    func testTrashedMailLeavesEveryViewAndCountAtOnceAndComesBackWhenMovedOut() async throws {
        let (store, ids) = try await seeded()
        let picnic = try XCTUnwrap(ids["Picnic"])
        let focusedBefore = try await store.categoryCounts()[.focused]
        XCTAssertEqual(focusedBefore?.total, 3)

        try await store.perform([MailChange(picnic, .move(from: "INBOX", to: "Deleted Messages"))])

        let all = try await subjects(store, SearchQuery())
        XCTAssertEqual(all, ["Garden", "Keep"], "All Mail")
        let inAccount = try await subjects(store, SearchQuery(account: account))
        XCTAssertEqual(inAccount, ["Garden", "Keep"], "the account's All")
        let focused = try await subjects(store, SearchQuery(category: .focused))
        XCTAssertEqual(focused, ["Garden", "Keep"], "Focused (unclassified mail counts as Focused)")
        let counts = try await store.categoryCounts()[.focused]
        XCTAssertEqual(counts?.total, 2)
        XCTAssertEqual(counts?.unread, 2)
        let unread = try await store.unreadCount()
        XCTAssertEqual(unread, 2)
        let trash = try await subjects(store, SearchQuery(account: account, mailbox: "Deleted Messages"))
        XCTAssertEqual(trash, ["Picnic"], "it is in Trash")
        let trashUnread = try await store.unreadCount(account: account, mailbox: "Deleted Messages")
        XCTAssertEqual(trashUnread, 1)

        // Search leaves it out, except inside Trash.
        let search = try await found(store, SearchQuery(text: "picnic"))
        XCTAssertEqual(search, [])
        let inTrash = try await found(store, SearchQuery.parse("picnic in:\"Deleted Messages\""))
        XCTAssertEqual(inTrash, ["Picnic"])
        let isTrash = try await store.isOnlyInTrashOrJunk(picnic)
        XCTAssertTrue(isTrash)

        // Back out of Trash: back everywhere.
        try await store.perform([MailChange(picnic, .move(from: "Deleted Messages", to: "INBOX"))])
        let back = try await subjects(store, SearchQuery(category: .focused))
        XCTAssertEqual(back, ["Garden", "Keep", "Picnic"])
        let backSearch = try await found(store, SearchQuery(text: "picnic"))
        XCTAssertEqual(backSearch, ["Picnic"])
        let backCounts = try await store.categoryCounts()[.focused]
        XCTAssertEqual(backCounts?.total, 3)
    }

    func testJunkAtTheProviderLeavesTheViewsAndACopyElsewhereKeepsItThere() async throws {
        let (store, ids) = try await seeded()
        let garden = try XCTUnwrap(ids["Garden"]), keep = try XCTUnwrap(ids["Keep"])
        // The provider moved Garden to Spam (the sync forgets the inbox UID and records the new one).
        try await store.forget(location("INBOX", 3), account: account)
        try await store.record(location("Spam", 1), for: garden, account: account)
        // Keep is in the inbox and, as a copy, in Trash: it is still in a folder of its own.
        try await store.record(location("Deleted Messages", 1), for: keep, account: account)

        let all = try await subjects(store, SearchQuery())
        XCTAssertEqual(all, ["Keep", "Picnic"])
        let junk = try await subjects(store, SearchQuery(account: account, mailbox: "Spam"))
        XCTAssertEqual(junk, ["Garden"])
        let trash = try await subjects(store, SearchQuery(account: account, mailbox: "Deleted Messages"))
        XCTAssertEqual(trash, ["Keep"])

        // Out of the inbox too: only in Trash now.
        try await store.forget(location("INBOX", 1), account: account)
        let left = try await subjects(store, SearchQuery())
        XCTAssertEqual(left, ["Picnic"])

        // Kept through a rebuilt index and a reopened store.
        try await store.rebuildIndex()
        let rebuilt = try await subjects(store, SearchQuery())
        XCTAssertEqual(rebuilt, ["Picnic"])
        let reopened = try await MailStore.open(locations)
        let again = try await subjects(reopened, SearchQuery())
        XCTAssertEqual(again, ["Picnic"])
        let stillInSpam = try await subjects(reopened, SearchQuery(account: account, mailbox: "Spam"))
        XCTAssertEqual(stillInSpam, ["Garden"])
    }

    func testAFolderThatGainsOrLosesTheRoleTakesItsMailWithIt() async throws {
        let (store, ids) = try await seeded()
        let picnic = try XCTUnwrap(ids["Picnic"])
        try await store.perform([MailChange(picnic, .move(from: "INBOX", to: "Work"))])
        var all = try await subjects(store, SearchQuery())
        XCTAssertEqual(all, ["Garden", "Keep", "Picnic"], "Work is an ordinary folder")

        // The provider now marks Work as its junk folder (or the account chose it, GKM-066).
        var folders = Self.folders
        folders[2].role = nil
        folders[3].role = "junk"
        try await store.replaceSyncedFolders(folders, account: account)
        all = try await subjects(store, SearchQuery())
        XCTAssertEqual(all, ["Garden", "Keep"])

        try await store.replaceSyncedFolders(Self.folders, account: account)
        all = try await subjects(store, SearchQuery())
        XCTAssertEqual(all, ["Garden", "Keep", "Picnic"])
    }

    func testWithoutATrashFolderTheTrashCreatedOnFirstUseCounts() async throws {
        let (store, ids) = try await seeded(folders: [SyncedFolder(name: "INBOX", path: ["INBOX"], role: "inbox")])
        XCTAssertEqual(MailStore.trashAndJunkFolders([SyncedFolder(name: "INBOX", path: ["INBOX"], role: "inbox")]), ["Trash": "trash"])
        XCTAssertEqual(MailStore.trashAndJunkFolders(Self.folders), ["Deleted Messages": "trash", "Spam": "junk"])
        XCTAssertEqual(MailStore.trashAndJunkFolders([]), [:], "nothing known about the account yet")
        let garden = try XCTUnwrap(ids["Garden"])
        try await store.perform([MailChange(garden, .move(from: "INBOX", to: "Trash", createTarget: true))])
        let all = try await subjects(store, SearchQuery())
        XCTAssertEqual(all, ["Keep", "Picnic"])
    }

    func testMailInNoFolderStaysVisible() async throws {
        let (store, ids) = try await seeded()
        let keep = try XCTUnwrap(ids["Keep"])
        // Deleted at the provider (MAIL-075): no folder left, kept and marked, still listed.
        try await store.forget(location("INBOX", 1), account: account)
        let all = try await subjects(store, SearchQuery())
        XCTAssertEqual(all, ["Garden", "Keep", "Picnic"])
        let isTrash = try await store.isOnlyInTrashOrJunk(keep)
        XCTAssertFalse(isTrash)
        // Imported into On My Mac: no folder at all.
        let imported = try await store.ingest(SyntheticMail.plain(subject: "Imported", body: "x"), account: MailAccountID("local")).id
        let shown = try await store.summaries(ids: [imported]).count
        XCTAssertEqual(shown, 1)
        let listed = try await subjects(store, SearchQuery(account: MailAccountID("local")))
        XCTAssertEqual(listed, ["Imported"])
    }

    func testSpacesSendersAndCleanUpLeaveTrashedMailOut() async throws {
        let (store, ids) = try await seeded()
        let picnic = try XCTUnwrap(ids["Picnic"])
        let space = try await store.createSpace(name: "Reading")
        _ = try await store.addMessages([picnic, try XCTUnwrap(ids["Keep"])], to: space.id)
        while try await store.classifyPending() > 0 {}
        let sendersBefore = try await store.senders(account: account).map(\.messages).reduce(0, +)
        XCTAssertEqual(sendersBefore, 3)

        try await store.perform([MailChange(picnic, .move(from: "INBOX", to: "Deleted Messages"))])

        let spaceCount = try await store.spaceCounts()[space.id]?.messages
        XCTAssertEqual(spaceCount, 1)
        let inSpace = try await subjects(store, SearchQuery(space: space.id))
        XCTAssertEqual(inSpace, ["Keep"])
        let senders = try await store.senders(account: account).map(\.messages).reduce(0, +)
        XCTAssertEqual(senders, 2)
        let fromAda = try await store.messages(of: .sender("ada@example.com"), account: account).compactMap(\.subject).sorted()
        XCTAssertEqual(fromAda, ["Garden", "Keep"])
        let overview = try await store.cleanupOverview()
        XCTAssertEqual(overview.composition.first?.total, 2)
        let arrivals = try await store.arrivals(after: 0).map(\.id)
        XCTAssertFalse(arrivals.contains(picnic), "no notification for mail already in Trash")
    }

    func testAnIndexFromSchemaSevenMarksTrashedMailWhenItOpens() async throws {
        do {
            let (store, ids) = try await seeded()
            try await store.perform([MailChange(try XCTUnwrap(ids["Garden"]), .move(from: "INBOX", to: "Spam"))])
        }
        let database = try SQLiteDatabase(url: locations.indexURL)
        try database.execute("""
            DROP TRIGGER trash_or_junk_after_message; DROP TRIGGER trash_or_junk_after_location_insert;
            DROP TRIGGER trash_or_junk_after_location_delete; DROP TRIGGER trash_or_junk_after_location_update;
            DROP TRIGGER trash_or_junk_after_folder_insert; DROP TRIGGER trash_or_junk_after_folder_delete;
            DROP TABLE trash_and_junk_mailboxes; ALTER TABLE messages DROP COLUMN trash_or_junk;
            """)
        try database.setUserVersion(7)
        let reopened = try await MailStore.open(locations)
        let version = try await reopened.indexSchemaForTesting()
        XCTAssertEqual(version, MailIndex.schemaVersion)
        let all = try await subjects(reopened, SearchQuery())
        XCTAssertEqual(all, ["Keep", "Picnic"], "migrated, then marked from the sync state")
        let count = try await reopened.messageCount()
        XCTAssertEqual(count, 3, "migrated, not rebuilt: nothing lost")
    }

    // MARK: Query plans

    /// The filter is one column of the row the view already reads: a view's plan is the same with
    /// it as without it (no join, no scan of another table), and keeping the mark right looks
    /// up nothing but primary keys.
    func testTheFilterAddsNothingToAViewsPlanAndTheMarkUsesPrimaryKeys() throws {
        let index = try MailIndex(url: root.appendingPathComponent("index.sqlite"))
        func viewSQL(_ query: SearchQuery) -> (String, String) {
            var without = query
            without.includesTrashAndJunk = true
            let order = "ORDER BY m.sort_date DESC, m.local_id"
            return ("SELECT \(MailIndex.summaryColumns) FROM messages m WHERE \(MailIndex.filterClause(query).0) \(order)",
                    "SELECT \(MailIndex.summaryColumns) FROM messages m WHERE \(MailIndex.filterClause(without).0) \(order)")
        }
        for query in [SearchQuery(), SearchQuery(account: account), SearchQuery(category: .subscriptions),
                      SearchQuery(category: .focused), SearchQuery(unreadOnly: true)] {
            let (with, without) = viewSQL(query)
            XCTAssertTrue(with.contains(MailIndex.notTrashOrJunk))
            let plan = try index.queryPlan(with)
            XCTAssertEqual(plan, try index.queryPlan(without), "\(query)")
            XCTAssertTrue(plan.contains { $0.contains("USING INDEX messages_by") }, "\(plan)")
        }
        let mark = try index.queryPlan("SELECT \(MailIndex.trashOrJunkExpression) FROM messages WHERE local_id = ?")
        XCTAssertFalse(mark.contains { $0.hasPrefix("SCAN") }, "\(mark)")
        // Both tables are read through their primary keys (SQLite names them sqlite_autoindex_…_1).
        XCTAssertTrue(mark.contains { $0.contains("SEARCH b USING") && $0.contains("sqlite_autoindex_message_mailboxes_1 (local_id=?)") }, "\(mark)")
        XCTAssertTrue(mark.contains { $0.contains("SEARCH t USING") && $0.contains("sqlite_autoindex_trash_and_junk_mailboxes_1 (account_id=? AND mailbox=?)") }, "\(mark)")
        let folder = try index.queryPlan("SELECT local_id FROM message_mailboxes WHERE account_id = ? AND mailbox = ?")
        XCTAssertTrue(folder.contains { $0.contains("message_mailboxes_by_mailbox") }, "a role change re-marks one folder through its index: \(folder)")
    }

    /// 50,000 messages, a tenth of them in Trash or Junk: the views, their counts and the mark
    /// stay fast. Heavy, so it runs when `GKM_BENCHMARK=1`:
    ///
    ///     GKM_BENCHMARK=1 swift test --filter TrashAndJunkTests
    func testFiftyThousandMessagesStayFast() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GKM_BENCHMARK"] == "1", "set GKM_BENCHMARK=1 to run the 50k benchmark")
        let count = 50_000
        let index = try MailIndex(url: root.appendingPathComponent("index.sqlite"))
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var ids: [MailMessageID] = []
        try index.replaceAll { insert in
            for n in 0..<count {
                let id = MailMessageID()
                ids.append(id)
                let from = MailAddress(name: "Person \(n % 300)", address: "person\(n % 300)@example.com")
                let front = MessageFrontMatter(
                    schema: 1, id: id, account: account, messageId: "m\(n)@example.com", inReplyTo: [], references: [],
                    from: [from], to: [], cc: [], replyTo: [], subject: "Message \(n)",
                    date: start.addingTimeInterval(Double(n) * 60), received: start, eml: "\(id).eml",
                    emlSha256: String(repeating: "0", count: 64), emlSize: 2_000, attachments: [])
                let message = ParsedMessage(messageID: front.messageId, from: [from], subject: front.subject, date: front.date, textBody: "body \(n)")
                try insert(IndexRecord(front: front, message: message, path: "accounts/x/\(id).eml"))
            }
        }
        func time<T>(_ label: String, _ body: () throws -> T) rethrows -> (T, TimeInterval) {
            let began = Date()
            let value = try body()
            let elapsed = Date().timeIntervalSince(began)
            print("BENCHMARK \(label): \(String(format: "%.1f", elapsed * 1_000)) ms")
            return (value, elapsed)
        }
        // Every tenth message in Trash, every twentieth of the rest in Junk.
        let (_, placing) = try time("folders for 50k messages (marks kept by the triggers)") {
            try index.restore(flags: [:], locations: ids.enumerated().map { n, id in
                (id, n % 10 == 0 ? "Trash" : n % 20 == 5 ? "Junk" : "INBOX")
            }, account: account)
        }
        XCTAssertLessThan(placing, 10)
        let (_, roles) = try time("Trash and Junk named (marks 7,500 messages)") {
            try index.setTrashAndJunkMailboxes(["Trash": "trash", "Junk": "junk"], account: account)
        }
        XCTAssertLessThan(roles, 5)
        let hidden = count / 10 + count / 20
        let (threads, threadTime) = try time("All Mail, first 200") { try index.threads(matching: SearchQuery(), limit: 200, offset: 0) }
        XCTAssertEqual(threads.count, 200)
        XCTAssertFalse(threads.contains { ids.firstIndex(of: $0.latest.id)! % 10 == 0 })
        XCTAssertLessThan(threadTime, 0.5)
        let (deep, deepTime) = try time("All Mail, page at 40,000") { try index.threads(matching: SearchQuery(), limit: 200, offset: 40_000) }
        XCTAssertEqual(deep.count, 200)
        XCTAssertLessThan(deepTime, 2)
        let (unread, unreadTime) = try time("unread count") { try index.unreadCount(account: nil, mailbox: nil) }
        XCTAssertEqual(unread, count - hidden)
        XCTAssertLessThan(unreadTime, 0.5)
        let (categories, categoryTime) = try time("category counts") { try index.categoryCounts(account: nil) }
        XCTAssertEqual(categories[.focused]?.total, count - hidden)
        XCTAssertLessThan(categoryTime, 0.5)
        let (trash, trashTime) = try time("Trash, first 200") { try index.threads(matching: SearchQuery(mailbox: "Trash"), limit: 200, offset: 0) }
        XCTAssertEqual(trash.count, 200)
        XCTAssertLessThan(trashTime, 0.5)
        let (_, moving) = try time("200 messages moved to Trash") {
            try index.batch { for id in ids.suffix(200) { try index.setMailboxes(["Trash"], for: id, account: account) } }
        }
        XCTAssertLessThan(moving, 0.5)
        let newlyHidden = (count - 200..<count).filter { $0 % 10 != 0 && $0 % 20 != 5 }.count
        XCTAssertEqual(try index.unreadCount(account: nil, mailbox: nil), count - hidden - newlyHidden)
    }
}
