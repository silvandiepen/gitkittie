import XCTest
import MailCore
@testable import MailStore

/// One sender's mail and selecting all of it (GKM-071, MAIL-098): the exact From filter across
/// accounts and folders, the ids Select All takes without loading rows, and the index behind it.
final class SenderSelectionTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let work = MailAccountID("work")
    private let home = MailAccountID("home")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm071-sender-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func eml(from: String, to: String, subject: String, day: Int, id: String, replyTo parent: String? = nil) -> Data {
        var headers = "From: \(from)\r\nTo: \(to)\r\nSubject: \(subject)\r\nDate: \(String(format: "%02d", day)) Nov 2026 09:00:00 +0000\r\nMessage-ID: <\(id)>\r\n"
        if let parent { headers += "In-Reply-To: <\(parent)>\r\n" }
        return Data((headers + "\r\nBody of \(subject).\r\n").utf8)
    }

    private func seed(_ store: MailStore) async throws {
        let mail: [(MailAccountID, String, String, String, String, String?)] = [
            (work, "INBOX", "Deals <deals@shop.example>", "Sale one", "s1@x", nil),
            (work, "Archive", "DEALS@SHOP.EXAMPLE", "Sale two", "s2@x", nil),
            (home, "INBOX", "Deals <deals@shop.example>", "Sale three", "s3@x", nil),
            // Someone else's address that contains it, and mail *to* it: never "from" it.
            (work, "INBOX", "Hot <hot-deals@shop.example>", "Not them", "o1@x", nil),
            (work, "Sent", "Ada <ada@example.com>", "Re: Sale one", "r1@x", "s1@x"),
        ]
        for (n, (account, folder, from, subject, id, parent)) in mail.enumerated() {
            let to = from.contains("ada@") ? "deals@shop.example" : "ada@example.com"
            try await store.ingest(eml(from: from, to: to, subject: subject, day: n + 1, id: id, replyTo: parent), account: account,
                                   remote: RemoteLocation(mailbox: folder, uidValidity: 1, uid: UInt32(n + 1)))
        }
    }

    func testTheSenderFilterIsExactAndCrossesAccountsAndFolders() async throws {
        let store = try await MailStore.open(locations)
        try await seed(store)
        let query = SearchQuery(sender: "Deals@Shop.Example")
        let subjects = try await store.search(query).compactMap(\.subject)
        XCTAssertEqual(subjects, ["Sale three", "Sale two", "Sale one"], "newest first, any case, both accounts, every folder")
        let participant = try await store.search(SearchQuery(participant: "deals@shop.example")).compactMap(\.subject)
        XCTAssertTrue(participant.contains("Re: Sale one"), "the person filter still finds mail to them; the sender filter does not")

        let ids = try await store.messageIDs(query)
        XCTAssertEqual(ids.count, 3)
        let summaries = try await store.summaries(of: ids + [MailMessageID()])
        XCTAssertEqual(Set(summaries.compactMap(\.subject)), ["Sale one", "Sale two", "Sale three"], "a missing id is left out")
        let threads = try await store.threadIDs(query)
        XCTAssertEqual(threads.count, 3, "one conversation per sale; the reply joins Sale one's")
        let firstPage = try await store.threads(query, limit: 3).map(\.id)
        XCTAssertEqual(threads, firstPage, "in the list's order")
    }

    func testSelectAllTakesEveryMatchNotOnlyThePage() async throws {
        let store = try await MailStore.open(locations)
        for n in 0..<450 {
            try await store.ingest(eml(from: "News <news@list.example>", to: "ada@example.com", subject: "Issue \(n)", day: 1 + n % 28, id: "n\(n)@x"),
                                   account: work, remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: UInt32(n + 1)))
        }
        let query = SearchQuery(sender: "news@list.example")
        let page = try await store.search(query, limit: 200)
        XCTAssertEqual(page.count, 200)
        let all = try await store.messageIDs(query)
        XCTAssertEqual(all.count, 450)
        XCTAssertEqual(Array(all.prefix(200)), page.map(\.id), "the ids follow the list's order")
        let threads = try await store.threadIDs(SearchQuery(account: work))
        XCTAssertEqual(threads.count, 450)
    }

    func testTheSenderQueryUsesTheSenderIndex() throws {
        let index = try MailIndex(url: root.appendingPathComponent("index.sqlite"))
        let (clause, _) = MailIndex.filterClause(SearchQuery(sender: "deals@shop.example"))
        let plan = try index.queryPlan("SELECT m.local_id FROM messages m WHERE \(clause) ORDER BY m.sort_date DESC")
        XCTAssertTrue(plan.contains { $0.contains("messages_by_sender") }, "\(plan)")
    }

    func testAnIndexAtSchemaEightGainsTheSenderIndexInPlace() async throws {
        do {
            let store = try await MailStore.open(locations)
            try await seed(store)
        }
        do {
            let index = try MailIndex(url: locations.indexURL)
            try index.database.execute("DROP INDEX messages_by_sender")
            try index.database.setUserVersion(8)
        }
        let index = try MailIndex(url: locations.indexURL)
        XCTAssertFalse(index.needsRebuild, "8 → 9 is a migration, not a rebuild")
        XCTAssertEqual(try index.database.userVersion, MailIndex.schemaVersion)
        let names = try index.database.prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'messages_by_sender'")
        XCTAssertTrue(try names.step())
        XCTAssertEqual(try index.messageIDs(matching: SearchQuery(sender: "deals@shop.example")).count, 3)
    }
}
