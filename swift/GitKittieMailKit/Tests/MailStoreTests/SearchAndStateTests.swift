import XCTest
import MailCore
import MailTestSupport
@testable import MailStore

/// GKM-016 search with filters, and the device state the list shows (folders, flags).
final class SearchAndStateTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let work = MailAccountID("work")
    private let home = MailAccountID("home")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testQuerySyntax() {
        let query = SearchQuery.parse(#"invoice from:ada "late fee" has:attachment is:unread in:INBOX after:2026-11-01 before:2026-12-01 to:"Bo Example" size:big"#, calendar: utc)
        XCTAssertEqual(query.text, #"invoice "late fee" size:big"#)
        XCTAssertEqual(query.participant, "ada Bo Example")
        XCTAssertTrue(query.hasAttachment)
        XCTAssertTrue(query.unreadOnly)
        XCTAssertEqual(query.mailbox, "INBOX")
        XCTAssertEqual(query.after, Date(timeIntervalSince1970: 1_793_491_200))
        XCTAssertEqual(query.before, Date(timeIntervalSince1970: 1_796_083_200))
        XCTAssertEqual(SearchQuery.parse("after:yesterday", calendar: utc).text, "after:yesterday", "an unreadable date stays text")
        XCTAssertEqual(MailIndex.matchQuery(#"café "late fee" NEAR(x)"#), #""café"* "late fee" "near"* "x"*"#)
    }

    func testFiltersNarrowSearchAndListing() async throws {
        let store = try await MailStore.open(locations)
        for (offset, eml) in SyntheticMail.corpus.enumerated() {
            try await store.ingest(eml, account: offset < 4 ? work : home,
                                   remote: RemoteLocation(mailbox: offset % 2 == 0 ? "INBOX" : "Archive", uidValidity: 1, uid: UInt32(offset + 1)))
        }
        func subjects(_ query: SearchQuery) async throws -> [String] { try await store.search(query).compactMap(\.subject) }

        let invoice = try await subjects(SearchQuery(text: "invoice"))
        XCTAssertEqual(invoice.count, 3)
        let withBo = try await subjects(SearchQuery(text: "invoice", participant: "bo@example.org"))
        XCTAssertEqual(Set(withBo), ["Re: Invoice 2026-114 for November", "Invoice 2026-114 for November", "Your receipt"],
                       "Bo sent one and received the others")
        let fromAda = try await subjects(SearchQuery(text: "invoice", participant: "ada"))
        XCTAssertEqual(Set(fromAda), ["Re: Invoice 2026-114 for November", "Invoice 2026-114 for November"])
        let fromBilling = try await subjects(SearchQuery(participant: "billing"))
        XCTAssertEqual(fromBilling, ["Your receipt"])
        let attachments = try await subjects(SearchQuery(hasAttachment: true))
        XCTAssertEqual(attachments, ["Garden plan"])
        let inbox = try await subjects(SearchQuery(account: work, mailbox: "inbox"))
        XCTAssertEqual(inbox, ["Re: Invoice 2026-114 for November", "Invoice 2026-114 for November"])
        let november = try await subjects(SearchQuery(after: utc.date(from: DateComponents(year: 2026, month: 11, day: 1)),
                                                      before: utc.date(from: DateComponents(year: 2026, month: 11, day: 24))))
        XCTAssertEqual(november, ["Your receipt", "Weekly garden news"])
        let folders = try await store.folders(account: work)
        XCTAssertEqual(folders, ["Archive", "INBOX"])
    }

    func testFlagsAndFoldersAreDeviceStateThatSurvivesARebuild() async throws {
        var receipt: MailMessageID!
        do {
            let store = try await MailStore.open(locations)
            for (offset, eml) in SyntheticMail.corpus.prefix(3).enumerated() {
                let id = try await store.ingest(eml, account: work, remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: UInt32(offset + 1))).id
                if offset == 1 { receipt = id }
            }
            let unread = try await store.unreadCount(account: work)
            XCTAssertEqual(unread, 3, "new mail is unread")
            try await store.setFlags(MessageFlags(seen: true, flagged: true), for: receipt)
            try await store.record(RemoteLocation(mailbox: "Receipts", uidValidity: 9, uid: 1), for: receipt, account: work)
            let after = try await store.unreadCount(account: work)
            XCTAssertEqual(after, 2)
        }
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: locations.indexURL.path + suffix) }
        let store = try await MailStore.open(locations)
        let flagged = try await store.search(SearchQuery(flaggedOnly: true)).map(\.id)
        XCTAssertEqual(flagged, [receipt])
        let receipts = try await store.search(SearchQuery(mailbox: "Receipts")).map(\.id)
        XCTAssertEqual(receipts, [receipt])
        let flags = try await store.flags(of: receipt)
        XCTAssertEqual(flags, MessageFlags(seen: true, flagged: true))
        let unread = try await store.threads(SearchQuery(unreadOnly: true)).map(\.unreadCount)
        XCTAssertEqual(unread, [2], "the invoice thread: two unread messages")

        // A UIDVALIDITY change empties the folder in the index too.
        _ = try await store.updateUIDValidity(10, mailbox: "Receipts", account: work)
        let emptied = try await store.search(SearchQuery(mailbox: "Receipts"))
        XCTAssertEqual(emptied, [])
        try await store.forget(RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 2), account: work)
        let inbox = try await store.search(SearchQuery(mailbox: "INBOX")).count
        XCTAssertEqual(inbox, 2)
    }

    func testImportedMailCanArriveRead() async throws {
        let store = try await MailStore.open(locations)
        let id = try await store.ingest(SyntheticMail.corpus[0], account: work, flags: MessageFlags(seen: true)).id
        let summary = try await store.search(SearchQuery()).first
        XCTAssertEqual(summary?.id, id)
        XCTAssertEqual(summary?.isUnread, false)
    }

    func testExtractedAttachmentTextIsSearchableAndSurvivesARebuild() async throws {
        do {
            let store = try await MailStore.open(locations)
            try await store.ingest(SyntheticMail.corpus[6], account: work) // plan.pdf
            let pending = try await store.attachmentsNeedingText(mediaTypes: ["application/pdf"])
            XCTAssertEqual(pending.map(\.mediaType), ["application/pdf"])
            let before = try await store.search("compost")
            XCTAssertEqual(before, [])
            try await store.recordAttachmentText("Raised beds, compost and a rain barrel.", forBlob: try XCTUnwrap(pending.first?.blob))
            let found = try await store.search("compost").map(\.subject)
            XCTAssertEqual(found, ["Garden plan"])
            let remaining = try await store.attachmentsNeedingText(mediaTypes: ["application/pdf"])
            XCTAssertEqual(remaining.count, 0, "extracted once, never again")
        }
        try FileManager.default.removeItem(at: locations.indexURL)
        let store = try await MailStore.open(locations)
        let found = try await store.search("compost").count
        XCTAssertEqual(found, 1, "the text comes back from the device cache")
        let mailFiles = try FileManager.default.subpathsOfDirectory(atPath: locations.mailFolder.path)
        XCTAssertFalse(mailFiles.contains { $0.hasSuffix(".txt") }, "extracted text never lands in the mail folder")
        await XCTAssertThrowsErrorAsync(try await store.recordAttachmentText("x", forBlob: "../../escape"))
    }

    func testHTMLOnlyMailIsSearchableAndItsMarkdownHasText() async throws {
        let store = try await MailStore.open(locations)
        let eml = Data("""
            From: Shop <shop@example.com>\r
            To: ada@example.com\r
            Subject: Your order\r
            Date: Tue, 24 Nov 2026 10:00:00 +0000\r
            Content-Type: text/html; charset=utf-8\r
            \r
            <html><body><p>Your <b>teapot</b> ships today.</p><script>var tracking = "zebra"</script></body></html>\r

            """.utf8)
        let id = try await store.ingest(eml, account: work).id
        let found = try await store.search("teapot").map(\.id)
        XCTAssertEqual(found, [id])
        let scripted = try await store.search("zebra")
        XCTAssertEqual(scripted, [], "script text is never indexed")
        let stored = try await store.message(id)
        XCTAssertTrue(stored.body.contains("Your teapot ships today."))
        XCTAssertFalse(stored.markdown.contains("<b>"))
        XCTAssertNotNil(stored.htmlBody)
    }
}
