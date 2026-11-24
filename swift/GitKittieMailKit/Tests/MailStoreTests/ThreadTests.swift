import XCTest
import MailCore
import MailTestSupport
@testable import MailStore

/// GKM-012: threads come from Message-ID, In-Reply-To and References only. Never subject,
/// never across accounts, and an ambiguous Message-ID merges nothing.
final class ThreadTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let account = MailAccountID("acct-1")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("threads-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func mail(_ subject: String, id: String?, inReplyTo: String? = nil, references: [String] = [], day: Int, body: String = "Text") -> Data {
        SyntheticMail.plain(subject: subject, date: "\(day) Nov 2026 10:00:00 +0000", messageID: id, inReplyTo: inReplyTo,
                            references: references.isEmpty ? nil : references.map { "<\($0)>" }.joined(separator: " "), body: body)
    }

    func testRepliesJoinTheirThreadInAnyOrder() async throws {
        let store = try await MailStore.open(locations)
        // The grandchild arrives first, then the root, then the middle message that links them.
        let c = try await store.ingest(mail("Re: Re: Plan", id: "c@example.com", inReplyTo: "b@example.com", references: ["a@example.com", "b@example.com"], day: 3), account: account).id
        let a = try await store.ingest(mail("Plan", id: "a@example.com", day: 1), account: account).id
        let threadsBefore = try await store.threads()
        XCTAssertEqual(threadsBefore.count, 1, "References alone already link c to a")
        let b = try await store.ingest(mail("Re: Plan", id: "b@example.com", inReplyTo: "a@example.com", day: 2), account: account).id

        let threads = try await store.threads()
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads.first?.messageCount, 3)
        XCTAssertEqual(threads.first?.latest.id, c)
        let members = try await store.thread(try XCTUnwrap(threads.first?.id)).map(\.id)
        XCTAssertEqual(members, [a, b, c], "oldest first")
        XCTAssertEqual(threads.first?.id, [a, b, c].min()?.rawValue, "the thread id is the smallest local id")
    }

    func testTheSameSubjectNeverMakesAThread() async throws {
        let store = try await MailStore.open(locations)
        try await store.ingest(mail("Lunch?", id: "one@example.com", day: 1), account: account)
        try await store.ingest(mail("Lunch?", id: "two@example.com", day: 2), account: account)
        try await store.ingest(mail("Re: Lunch?", id: nil, day: 3), account: account)
        let count = try await store.threads().count
        XCTAssertEqual(count, 3)
    }

    func testAMessageWithoutMessageIDStillJoinsByItsReplyHeaders() async throws {
        let store = try await MailStore.open(locations)
        try await store.ingest(mail("Plan", id: "a@example.com", day: 1), account: account)
        try await store.ingest(mail("Re: Plan", id: nil, inReplyTo: "a@example.com", day: 2), account: account)
        let threads = try await store.threads()
        XCTAssertEqual(threads.map(\.messageCount), [2])
    }

    func testAnAmbiguousMessageIDMergesNothing() async throws {
        let store = try await MailStore.open(locations)
        let first = try await store.ingest(try MailFixtures.message("mal-duplicate-message-id-a.eml"), account: account).id
        let reply = try await store.ingest(mail("Re: Slides", id: "reply@example.com", inReplyTo: "dup-4711@mail.example.net", day: 26), account: account).id
        let joined = try await store.threads()
        XCTAssertEqual(joined.map(\.messageCount), [2], "while the id is unique, the reply joins it")

        // A different message claiming the same Message-ID makes that id ambiguous: it now links
        // nothing, so the earlier thread splits and the newcomer stands alone.
        let second = try await store.ingest(try MailFixtures.message("mal-duplicate-message-id-b.eml"), account: account).id
        let threads = try await store.threads()
        XCTAssertEqual(threads.count, 3)
        let ids = Set(threads.map(\.latest.id))
        XCTAssertEqual(ids, [first, second, reply])

    }

    func testTwoCopiesOfTheSameMessageShareTheirID() async throws {
        let store = try await MailStore.open(locations)
        try await store.ingest(try MailFixtures.message("mal-duplicate-message-id-a.eml"), account: account)
        try await store.ingest(try MailFixtures.message("mal-duplicate-message-id-a.eml"), account: account)
        let counts = try await store.threads().map(\.messageCount)
        XCTAssertEqual(counts, [2])
    }

    func testThreadsNeverCrossAccounts() async throws {
        let store = try await MailStore.open(locations)
        try await store.ingest(mail("Plan", id: "a@example.com", day: 1), account: account)
        try await store.ingest(mail("Re: Plan", id: "b@example.com", inReplyTo: "a@example.com", day: 2), account: MailAccountID("other"))
        let count = try await store.threads().count
        XCTAssertEqual(count, 2)
    }

    func testAHostileReferencesHeaderIsCapped() async throws {
        let store = try await MailStore.open(locations)
        let references = (0..<5_000).map { "spray-\($0)@example.net" }
        try await store.ingest(mail("Spray", id: "spray@example.com", references: references, day: 1), account: account)
        // Only the last 100 references count: a message naming the 4,999th joins, the 1st does not.
        try await store.ingest(mail("Old", id: "spray-0@example.net", day: 2), account: account)
        try await store.ingest(mail("New", id: "spray-4999@example.net", day: 3), account: account)
        let counts = try await store.threads().map(\.messageCount).sorted()
        XCTAssertEqual(counts, [1, 2])
    }

    func testRebuiltThreadsMatchIncrementalOnesOverTheFixtureCorpus() async throws {
        var before: [String: [MailMessageID]] = [:]
        do {
            let store = try await MailStore.open(locations)
            for url in try MailFixtures.messageURLs() { try await store.ingest(Data(contentsOf: url), account: account) }
            for eml in SyntheticMail.corpus { try await store.ingest(eml, account: account) }
            for thread in try await store.threads(limit: 1_000) { before[thread.id] = try await store.thread(thread.id).map(\.id) }
        }
        XCTAssertTrue(before.values.contains { $0.count == 2 }, "the invoice and its reply form a thread")
        try FileManager.default.removeItem(at: locations.indexURL)
        let rebuilt = try await MailStore.open(locations)
        var after: [String: [MailMessageID]] = [:]
        for thread in try await rebuilt.threads(limit: 1_000) { after[thread.id] = try await rebuilt.thread(thread.id).map(\.id) }
        XCTAssertEqual(after, before)
    }
}

extension MailFixtures {
    static func message(_ name: String) throws -> Data {
        guard let url = try messageURLs().first(where: { $0.lastPathComponent == name }) else { throw FixtureError.missingDirectory }
        return try Data(contentsOf: url)
    }
}
