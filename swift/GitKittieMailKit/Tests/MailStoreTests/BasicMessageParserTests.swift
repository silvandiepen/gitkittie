import XCTest
import MailCore
@testable import MailStore

final class BasicMessageParserTests: XCTestCase {
    private let parser = BasicMessageParser()

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
        XCTAssertEqual(message.date, Date(timeIntervalSince1970: 1_795_511_700)) // 2026-11-24T09:15:00Z
        XCTAssertEqual(message.textBody, "Body\n")
    }

    func testAddressListsWithQuotesCommentsAndGroups() {
        let list = MIME.addresses(#""Doe, Jamie" <jamie@example.com>, bo@example.org (Bo E.), Team: x@example.net, y@example.net;, <z@example.com>"#)
        XCTAssertEqual(list, [
            MailAddress(name: "Doe, Jamie", address: "jamie@example.com"),
            MailAddress(name: "Bo E.", address: "bo@example.org"),
            MailAddress(address: "x@example.net"),
            MailAddress(address: "y@example.net"),
            MailAddress(address: "z@example.com"),
        ])
        XCTAssertEqual(MIME.addresses("undisclosed-recipients:;"), [])
    }

    func testMessageIDListsAndDates() {
        XCTAssertEqual(MIME.messageIDs("<a@example.com> <b@example.org>\r\n\t<c@example.net>"), ["a@example.com", "b@example.org", "c@example.net"])
        // Obsolete forms: no weekday, two-digit year, named zone, a comment.
        XCTAssertEqual(MIME.date("24 Nov 26 10:15 EST (Eastern)"), Date(timeIntervalSince1970: 1_795_533_300)) // 15:15Z
        XCTAssertEqual(MIME.date("Tue, 24 Nov 2026 10:15:00 -0000"), Date(timeIntervalSince1970: 1_795_515_300))
        XCTAssertNil(MIME.date("not a date"))
    }

    func testQuotedPrintableWithCharset() throws {
        let eml = Data("""
        From: a@example.com\r
        Subject: qp\r
        Content-Type: text/plain; charset="iso-8859-1"\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        Caf=E9 au lait, a long line that is =\r
        soft-broken.\r

        """.utf8)
        XCTAssertEqual(try parser.parse(eml).textBody, "Café au lait, a long line that is soft-broken.\n")
    }

    func testMultipartAlternativeWithAttachmentAndRFC2231Name() throws {
        let eml = Data("""
        From: a@example.com\r
        Subject: parts\r
        Content-Type: multipart/mixed; boundary=outer\r
        \r
        --outer\r
        Content-Type: multipart/alternative; boundary="inner"\r
        \r
        --inner\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Plain version\r
        --inner\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>HTML version</p>\r
        --inner--\r
        --outer\r
        Content-Type: application/octet-stream\r
        Content-Disposition: attachment; filename*=utf-8''r%C3%A9sum%C3%A9.txt\r
        Content-Transfer-Encoding: base64\r
        \r
        aGVsbG8=\r
        --outer--\r

        """.utf8)
        let message = try parser.parse(eml)
        XCTAssertEqual(message.textBody, "Plain version")
        XCTAssertTrue(message.hasHTMLBody)
        XCTAssertEqual(message.attachments.count, 1)
        XCTAssertEqual(message.attachments.first?.fileName, "résumé.txt")
        XCTAssertEqual(message.attachments.first?.data, Data("hello".utf8))
    }

    func testHTMLOnlyMessageHasNoTextBody() throws {
        let eml = Data("From: a@example.com\r\nContent-Type: text/html\r\n\r\n<b>Hi</b>\r\n".utf8)
        let message = try parser.parse(eml)
        XCTAssertNil(message.textBody)
        XCTAssertTrue(message.hasHTMLBody)
    }

    func testNestingBeyondTheLimitIsNotFollowed() throws {
        var body = "Deep text\r\n"
        for level in 0..<(BasicMessageParser.maximumDepth + 2) {
            body = "Content-Type: multipart/mixed; boundary=b\(level)\r\n\r\n--b\(level)\r\n\(level == 0 ? "Content-Type: text/plain\r\n\r\n" : "")\(body)--b\(level)--\r\n"
        }
        let message = try parser.parse(Data(("From: a@example.com\r\n" + body).utf8))
        XCTAssertNil(message.textBody, "parts below the depth limit stay in the .eml only")
    }

    func testBytesWithoutHeadersAreRejected() {
        XCTAssertThrowsError(try parser.parse(Data("just some text\nwithout any header\n".utf8)))
        XCTAssertThrowsError(try parser.parse(Data()))
    }
}
