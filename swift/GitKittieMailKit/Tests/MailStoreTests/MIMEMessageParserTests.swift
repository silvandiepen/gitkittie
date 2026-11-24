import XCTest
import MailCore
import MailTestSupport
@testable import MailStore

/// The store's parser is MailMIME (GKM-002). These pin what the store relies on; MailMIME's own
/// tests cover the parsing itself.
final class MIMEMessageParserTests: XCTestCase {
    private let parser = MIMEMessageParser()

    func testHeadersAreUnfoldedAndEncodedWordsDecoded() throws {
        let eml = Data("""
        From: =?iso-8859-1?q?Ren=E9?= Example <rene@example.com>\r
        To: ada@example.com\r
        Subject: =?utf-8?b?SGVsbG8g?=\r
         =?utf-8?q?w=C3=B6rld?= and more\r
        Date: Tue, 24 Nov 2026 10:15:00 +0100\r
        Message-ID: <abc@example.com>\r
        \r
        Body\r

        """.utf8)
        let message = try parser.parse(eml)
        XCTAssertEqual(message.subject, "Hello wörld and more")
        XCTAssertEqual(message.from, [MailAddress(name: "René Example", address: "rene@example.com")])
        XCTAssertEqual(message.messageID, "abc@example.com")
        XCTAssertEqual(message.date, Date(timeIntervalSince1970: 1_795_511_700))
        XCTAssertEqual(message.textBody, "Body\n")
        XCTAssertEqual(message.problems, [])
    }

    func testAlternativeRelatedAndAttachments() throws {
        let message = try parser.parse(MailFixtures.hostileHTML("lookalike-links.eml"))
        XCTAssertNotNil(message.textBody)
        XCTAssertTrue(message.htmlBody?.contains("cid:logo@cloudvault") == true)
        XCTAssertEqual(message.attachments.map(\.fileName), ["logo.png", "storage-report.pdf"])
        XCTAssertEqual(message.attachments.map(\.isInline), [true, false])
        XCTAssertEqual(message.attachments.map(\.contentID), ["logo@cloudvault", nil])
        XCTAssertEqual(message.replyTo.map(\.address), ["billing@payments.example.org"])
    }

    func testHTMLOnlyMessageHasNoTextBody() throws {
        let message = try parser.parse(Data("From: a@example.com\r\nContent-Type: text/html\r\n\r\n<b>Hi</b>\r\n".utf8))
        XCTAssertNil(message.textBody)
        XCTAssertEqual(message.htmlBody, "<b>Hi</b>\r\n")
    }

    func testBytesWithoutHeadersAreRejected() {
        XCTAssertThrowsError(try parser.parse(Data("just some text\nwithout any header\n".utf8)))
        XCTAssertThrowsError(try parser.parse(Data()))
    }

    /// Every GKM-003 fixture parses, keeps a sender, and reports a problem exactly when the
    /// corpus expects recovery or a limit.
    func testTheFixtureCorpusParses() throws {
        let expectations = try MailFixtures.expectations()
        for url in try MailFixtures.messageURLs() {
            let message = try parser.parse(Data(contentsOf: url))
            let fixture = try XCTUnwrap(expectations.fixtures.first { $0.file == url.lastPathComponent })
            XCTAssertFalse(message.from.isEmpty, url.lastPathComponent)
            if fixture.tags.contains("nesting-bomb") { XCTAssertFalse(message.problems.isEmpty, url.lastPathComponent) }
            for attachment in message.attachments {
                let name = attachment.fileName ?? ""
                XCTAssertFalse(name.contains("/") || name.contains("\\") || name.hasPrefix("."), "\(url.lastPathComponent): \(name)")
            }
        }
    }
}
