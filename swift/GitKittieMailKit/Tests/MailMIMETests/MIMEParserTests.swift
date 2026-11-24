import Foundation
import MailCore
import XCTest
@testable import MailMIME

final class MIMEParserTests: XCTestCase {
    private func crlf(_ text: String) -> Data { Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

    func testSimpleMessageHeadersAndBody() {
        let message = MIMEParser.parse(crlf("""
        From: "Doe, Jane" <jane@example.com>
        To: bob@example.org (Bob), =?UTF-8?Q?Ren=C3=A9?= <rene@example.net>
        Subject: =?UTF-8?B?SGFsbG8gd8OkcmVsZA==?= =?UTF-8?Q?_again?=
        Date: Tue, 24 Nov 2026 13:05:00 +0100
        Message-ID: <abc.123@example.com>
        References: <one@example.com>
         <two@example.com>

        Hello there.
        """))
        XCTAssertEqual(message.problems, [])
        XCTAssertEqual(message.subject, "Hallo wäreld again")
        XCTAssertEqual(message.from, [MailAddress(name: "Doe, Jane", address: "jane@example.com")])
        XCTAssertEqual(message.to, [MailAddress(name: "Bob", address: "bob@example.org"),
                                    MailAddress(name: "René", address: "rene@example.net")])
        XCTAssertEqual(message.messageID, "abc.123@example.com")
        XCTAssertEqual(message.references, ["one@example.com", "two@example.com"])
        XCTAssertEqual(message.date, Date(timeIntervalSince1970: 1_795_521_900))
        XCTAssertEqual(message.textBody, "Hello there.")
    }

    func testMultipartWithAttachmentsAndEncodings() {
        let message = MIMEParser.parse(crlf("""
        From: a@example.com
        Content-Type: multipart/mixed; boundary="outer"

        preamble
        --outer
        Content-Type: multipart/alternative; boundary=inner

        --inner
        Content-Type: text/plain; charset=iso-8859-1
        Content-Transfer-Encoding: quoted-printable

        Caf=E9 soft=
        break
        --inner
        Content-Type: text/html; charset=utf-8

        <p>Café</p>
        --inner--
        --outer
        Content-Type: application/pdf; name="ignored.pdf"
        Content-Disposition: attachment; filename*0*=UTF-8''%E2%82%AC%20; filename*1="report.pdf"
        Content-Transfer-Encoding: base64

        JVBERi0x
        LjQK
        --outer--
        epilogue
        """))
        XCTAssertEqual(message.problems, [])
        XCTAssertEqual(message.textBody, "Café softbreak")
        XCTAssertEqual(message.htmlBody, "<p>Café</p>")
        XCTAssertEqual(message.attachments.count, 1)
        XCTAssertEqual(message.attachments.first?.filename, "€ report.pdf")
        XCTAssertEqual(message.attachments.first?.body, Data("%PDF-1.4\n".utf8))
    }

    func testBareLineFeedsAndMissingClosingBoundary() {
        let message = MIMEParser.parse(Data("""
        Content-Type: multipart/mixed; boundary=b

        --b
        Content-Type: text/plain

        only part
        """.utf8))
        XCTAssertEqual(message.textBody, "only part")
        XCTAssertTrue(message.problems.contains { $0.contains("closing boundary") })
    }

    func testHostileInputIsBoundedNotFatal() {
        // 100 nested multiparts: parsing stops at the depth limit instead of recursing on.
        var text = ""
        for i in 0..<100 { text += "Content-Type: multipart/mixed; boundary=b\(i)\r\n\r\n--b\(i)\r\n" }
        text += "Content-Type: text/plain\r\n\r\ndeep\r\n"
        let message = MIMEParser.parse(Data(text.utf8))
        XCTAssertTrue(message.problems.contains { $0.contains("nesting deeper") })

        let noBoundary = MIMEParser.parse(Data("Content-Type: multipart/mixed\r\n\r\nbody".utf8))
        XCTAssertEqual(noBoundary.root.mimeType, "application/octet-stream")
    }

    func testFilenamesCannotEscapeTheirFolder() {
        XCTAssertEqual(MIMEPart.safeFilename("../../etc/passwd"), "_.._etc_passwd")
        XCTAssertEqual(MIMEPart.safeFilename("..\\..\\boot.ini"), "_.._boot.ini")
        XCTAssertEqual(MIMEPart.safeFilename(".hidden"), "hidden")
        XCTAssertEqual(MIMEPart.safeFilename("invoice\u{202E}fdp.exe"), "invoice_fdp.exe")
        XCTAssertEqual(MIMEPart.safeFilename(""), "attachment")
    }

    func testEncodedWordEdgeCases() {
        XCTAssertEqual(EncodedWords.decode("=?iso-8859-1?q?this=20is=20some=20text?="), "this is some text")
        XCTAssertEqual(EncodedWords.decode("=?UTF-8?B?w6k=?= =?UTF-8?B?w6k=?="), "éé")
        XCTAssertEqual(EncodedWords.decode("plain =?bogus"), "plain =?bogus")
        XCTAssertEqual(EncodedWords.decode("=?UTF-8*en?Q?Hi?="), "Hi")
        XCTAssertEqual(EncodedWords.decode("a =?UTF-8?Q?b?= c"), "a b c")
    }

    func testAddressGroupsAndComments() {
        let list = AddressParser.parseList("Team: a@example.com, \"B, Q\" <b@example.com>;, c@example.org")
        XCTAssertEqual(list.map(\.address), ["a@example.com", "b@example.com", "c@example.org"])
        XCTAssertEqual(list[1].name, "B, Q")
        XCTAssertEqual(AddressParser.parseList("undisclosed-recipients:;"), [])
    }

    func testDatesWithObsoleteZonesAndNoWeekday() {
        XCTAssertEqual(MailDates.parse("24 Nov 2026 12:00:00 GMT"), Date(timeIntervalSince1970: 1_795_521_600))
        XCTAssertEqual(MailDates.parse("Tue, 24 Nov 26 07:00 EST"), Date(timeIntervalSince1970: 1_795_521_600))
        XCTAssertNil(MailDates.parse("yesterday"))
    }
}

final class MIMEBuilderTests: XCTestCase {
    func testBuiltMessageParsesBackExactly() throws {
        let pdf = Data((0..<3000).map { UInt8($0 % 256) })
        let builder = MIMEBuilder(
            from: MailAddress(name: "Zoë Test", address: "zoe@example.com"),
            to: [MailAddress(name: "Doe, Jane", address: "jane@example.org")],
            cc: [MailAddress(address: "cc@example.net")],
            bcc: [MailAddress(address: "hidden@example.net")],
            subject: "Überweisung — a long subject line that has to be folded across more than one line of header",
            date: Date(timeIntervalSince1970: 1_795_521_600),
            messageID: "fixed.1@example.com",
            inReplyTo: "parent@example.org",
            references: ["root@example.org", "parent@example.org"],
            textBody: "Hello,\n.leading dot\nnaïve café\n" + String(repeating: "long ", count: 40) + "\n",
            htmlBody: "<p>Hello</p>",
            attachments: [OutgoingAttachment(filename: "../Rapport €.pdf", mimeType: "application/pdf", data: pdf)]
        )
        let data = builder.build()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("hidden@example.net"), "Bcc must not be in the message")
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "only CRLF line breaks")
        for line in text.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.utf8.count, 998, "RFC 5322 line length")
        }
        XCTAssertEqual(builder.recipients, ["jane@example.org", "cc@example.net", "hidden@example.net"])

        let parsed = MIMEParser.parse(data)
        XCTAssertEqual(parsed.problems, [])
        XCTAssertEqual(parsed.subject, builder.subject)
        XCTAssertEqual(parsed.from, [builder.from])
        XCTAssertEqual(parsed.to, builder.to)
        XCTAssertEqual(parsed.messageID, "fixed.1@example.com")
        XCTAssertEqual(parsed.inReplyTo, ["parent@example.org"])
        XCTAssertEqual(parsed.references, ["root@example.org", "parent@example.org"])
        XCTAssertEqual(parsed.date, builder.date)
        XCTAssertEqual(parsed.textBody, builder.textBody.replacingOccurrences(of: "\n", with: "\r\n"))
        XCTAssertEqual(parsed.htmlBody, "<p>Hello</p>")
        XCTAssertEqual(parsed.attachments.count, 1)
        XCTAssertEqual(parsed.attachments.first?.filename, "_Rapport €.pdf")
        XCTAssertEqual(parsed.attachments.first?.body, pdf)
    }

    func testHeaderInjectionIsNeutralised() {
        let builder = MIMEBuilder(
            from: MailAddress(address: "a@example.com"), to: [MailAddress(address: "b@example.com")],
            subject: "Hi\r\nBcc: victim@example.org", textBody: "x",
            extraHeaders: [("X-Note", "one\r\nBcc: victim@example.org"), ("Bcc", "victim@example.org")]
        )
        let parsed = MIMEParser.parse(builder.build())
        XCTAssertNil(parsed.headers["Bcc"])
        XCTAssertEqual(parsed.headers.decoded("X-Note"), "one  Bcc: victim@example.org")
    }

    func testMessageIDsAreUniqueAndUseTheSenderDomain() {
        let a = MIMEBuilder.makeMessageID(for: "me@example.com")
        let b = MIMEBuilder.makeMessageID(for: "me@example.com")
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasSuffix("@example.com"))
    }
}
