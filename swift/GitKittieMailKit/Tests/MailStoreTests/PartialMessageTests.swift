import XCTest
import MailCore
import MailTestSupport
@testable import MailStore

/// Partial messages (GKM-036) at the store level: which parts may be left at the provider, the
/// skeleton they leave, and the index migration to schema 6. The behaviour against a real
/// server (fetch on demand, completion, pins, eviction) is in OnDemandIntegrationTests.
final class PartialMessageTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let account = MailAccountID("acct-partial")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("partial-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// multipart/mixed: (alternative: text, html), a 2 MB PDF, a 10 KB image, a 3 MB text log
    /// marked as an attachment, a 5 MB text part with no name (body text, never left out).
    private var structure: MessagePart {
        MessagePart(section: "", mediaType: "multipart/mixed", boundary: "outer", size: 0, parts: [
            MessagePart(section: "1", mediaType: "multipart/alternative", boundary: "inner", size: 0, parts: [
                MessagePart(section: "1.1", mediaType: "text/plain", encoding: "quoted-printable", size: 2_000),
                MessagePart(section: "1.2", mediaType: "text/html", encoding: "quoted-printable", size: 6_000),
            ]),
            MessagePart(section: "2", mediaType: "application/pdf", encoding: "base64", size: 2_000_000, fileName: "report.pdf",
                        disposition: "attachment"),
            MessagePart(section: "3", mediaType: "image/png", encoding: "base64", size: 10_000, fileName: "logo.png"),
            MessagePart(section: "4", mediaType: "text/plain", encoding: "base64", size: 3_000_000, fileName: "server.log",
                        disposition: "attachment"),
            MessagePart(section: "5", mediaType: "text/plain", encoding: "7bit", size: 5_000_000),
        ])
    }

    func testOnlyLargeAttachmentsAreLeftAtTheProviderAndTextAlwaysComes() {
        XCTAssertEqual(PartialPlan.omitted(structure, threshold: 1_000_000).map(\.section), ["2", "4"])
        let sections = PartialPlan.sections(of: structure, threshold: 1_000_000)
        XCTAssertEqual(sections, ["HEADER", "1.MIME", "1", "2.MIME", "3.MIME", "3", "4.MIME", "5.MIME", "5"],
                       "the alternative holds nothing left out: fetched as one unit")
        XCTAssertNil(PartialPlan.sections(of: structure, threshold: 10_000_000), "nothing to leave out: fetched whole")
        var broken = structure
        broken.boundary = nil
        XCTAssertNil(PartialPlan.sections(of: broken, threshold: 1_000_000), "no skeleton without a boundary")
    }

    func testTheSkeletonParsesWithItsTextAndListsLeftOutPartsAsNotDownloaded() async throws {
        let crlf = "\r\n"
        func mime(_ lines: String...) -> Data { Data((lines.joined(separator: crlf) + crlf + crlf).utf8) }
        let header = Data(("From: Ada <ada@example.com>\r\nTo: Bo <bo@example.com>\r\nSubject: Figures\r\n"
                           + "Date: Tue, 24 Nov 2026 10:00:00 +0000\r\nMessage-ID: <figures@example.com>\r\nMIME-Version: 1.0\r\n"
                           + "Content-Type: multipart/mixed; boundary=\"outer\"\r\n\r\n").utf8)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        let sections: [String: Data] = [
            "1.MIME": mime("Content-Type: multipart/alternative; boundary=\"inner\""),

            "2.MIME": mime("Content-Type: application/pdf; name=\"report.pdf\"", "Content-Transfer-Encoding: base64",
                           "Content-Disposition: attachment; filename=\"report.pdf\""),
            "3.MIME": mime("Content-Type: image/png; name=\"logo.png\"", "Content-Transfer-Encoding: base64"),
            "4.MIME": mime("Content-Type: text/plain; name=\"server.log\"", "Content-Transfer-Encoding: base64",
                           "Content-Disposition: attachment; filename=\"server.log\""),
            "5.MIME": mime("Content-Type: text/plain; charset=utf-8"),
            "1": Data(("--inner\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nThe figures are attached.\r\n"
                       + "--inner\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>The figures are attached.</p>\r\n--inner--\r\n").utf8),
            "3": Data(png.base64EncodedString().utf8),
            "5": Data("A long appendix.".utf8),
        ]
        XCTAssertTrue(PartialPlan.isConsistent(structure, sections: sections))
        var wrong = sections
        wrong["3.MIME"] = mime("Content-Type: multipart/alternative; boundary=\"inner\"")
        XCTAssertFalse(PartialPlan.isConsistent(structure, sections: wrong), "a server answering with the wrong part is caught")
        let store = try await MailStore.open(locations)
        let message = SyncedPartialMessage(header: header, structure: structure, sections: sections, size: 5_100_000,
                                           remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 7),
                                           receivedAt: Date(timeIntervalSince1970: 1_795_600_000), flags: MailMessageFlags())
        let outcomes = try await store.storeSyncedPartials([message], account: account)
        guard case .stored(let id)? = outcomes.first else { return XCTFail("\(outcomes)") }

        let stored = try await store.message(id)
        XCTAssertTrue(stored.isPartial)
        XCTAssertEqual(stored.textBody?.hasPrefix("The figures are attached."), true)
        let attachments = stored.front.attachments
        XCTAssertEqual(attachments.map(\.fileName), ["report.pdf", "logo.png", "server.log"])
        XCTAssertEqual(attachments.map(\.isDownloaded), [false, true, false])
        XCTAssertEqual(attachments.map(\.section), ["2", nil, "4"])
        let logo = try await store.attachmentData(attachments[1])
        XCTAssertEqual(logo, png)
        XCTAssertEqual(stored.front.emlSha256, "", "no original, no hash to check")
        let original = FileManager.default.subpaths(atPath: locations.mailFolder.path)?.filter { $0.hasSuffix(".eml") }
        XCTAssertEqual(original ?? [], [], "nothing in the mail folder")

        // The same copy again (a second folder) matches; a reopen and a rebuild keep it.
        var copy = message
        copy.remote = RemoteLocation(mailbox: "Archive", uidValidity: 1, uid: 3)
        let again = try await store.storeSyncedPartials([copy], account: account)
        XCTAssertEqual(again, [.matched(id)])
        try await store.rebuildIndex()
        let reopened = try await MailStore.open(locations)
        let partial = try await reopened.partialMessages(account: account)
        XCTAssertEqual(partial, [id])
        let status = try await reopened.partialStatus(id)
        XCTAssertEqual(status?.missing.map(\.section), ["2", "4"])
        XCTAssertEqual(Set(status?.locations.map(\.mailbox) ?? []), ["INBOX", "Archive"])
    }

    func testASchemaFiveIndexIsMigratedInPlace() async throws {
        let data = try Data(contentsOf: XCTUnwrap(MailFixtures.directory?.appendingPathComponent("promo-sale-en.eml")))
        do {
            let store = try await MailStore.open(locations)
            _ = try await store.ingest(data, account: account)
            try await store.downgradeToSchemaFiveForTesting()
        }
        let store = try await MailStore.open(locations)
        let pending = try await store.pendingClassificationCount()
        XCTAssertEqual(pending, 0, "verdicts kept: migrated, not rebuilt")
        let schema = try await store.indexSchemaForTesting()
        XCTAssertEqual(schema, 7, "on through 6 → 7 (provider deletions, MAIL-075) as well")
        let listed = try await store.search(SearchQuery())
        XCTAssertEqual(listed.count, 1, "summaries read the new table")
        XCTAssertNil(listed.first?.deletedAtProvider)
        let count = try await store.messageCount()
        XCTAssertEqual(count, 1)
        let partial = try await store.partialMessages()
        XCTAssertEqual(partial, [], "everything indexed before is complete")
        let library = try await store.attachments(AttachmentQuery())
        XCTAssertTrue(library.allSatisfy { $0.reference.section == nil && $0.reference.isDownloaded })
    }
}

extension MailStore {
    func downgradeToSchemaFiveForTesting() throws {
        try index.database.execute("""
            DROP INDEX messages_partial; ALTER TABLE messages DROP COLUMN partial; ALTER TABLE message_blobs DROP COLUMN section;
            DROP TABLE provider_deletions;
            """)
        try index.database.setUserVersion(5)
    }

    func indexSchemaForTesting() throws -> Int { try index.database.userVersion }
}
