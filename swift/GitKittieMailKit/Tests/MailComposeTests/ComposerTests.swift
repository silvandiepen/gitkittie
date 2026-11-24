import Foundation
import MailCore
import MailMIME
import XCTest
@testable import MailCompose

final class ComposerTests: XCTestCase {
    private let me = MailAddress(name: "Alex Morgan", address: "alex.morgan@example.net")

    private func draft(_ body: String = "Hello **there**.") -> ComposeDraft {
        ComposeDraft(from: me, to: [MailAddress(name: "Kim", address: "kim@example.org")],
                     cc: [MailAddress(address: "lee@example.com")],
                     bcc: [MailAddress(name: "Secret", address: "hidden@example.com")],
                     subject: "Plans", body: body)
    }

    func testSendsMarkdownAsPlainTextAndGeneratedHTML() throws {
        let composed = try MessageComposer.compose(draft("Hello **there**.\n\n- one\n- two"), attachments: [], messageID: "fixed@example.net")
        let message = MIMEParser.parse(composed.rawMessage)
        XCTAssertEqual(message.problems, [])
        XCTAssertEqual(message.root.mimeType, "multipart/alternative")
        XCTAssertEqual(message.textBody?.replacingOccurrences(of: "\r\n", with: "\n"), "Hello **there**.\n\n- one\n- two")
        let html = try XCTUnwrap(message.htmlBody).replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertTrue(html.contains("<p>Hello <strong>there</strong>.</p>"), html)
        XCTAssertTrue(html.contains("<ul>\n<li>one</li>\n<li>two</li>\n</ul>"), html)
        XCTAssertEqual(message.messageID, "fixed@example.net")
        XCTAssertEqual(composed.messageID, "fixed@example.net")
        XCTAssertEqual(composed.envelopeFrom, "alex.morgan@example.net")
    }

    /// GKM-013/014: Bcc is envelope only.
    func testBccIsInTheEnvelopeAndNowhereInTheMessage() throws {
        let composed = try MessageComposer.compose(draft(), attachments: [])
        XCTAssertEqual(composed.recipients, ["kim@example.org", "lee@example.com", "hidden@example.com"])
        XCTAssertEqual(composed.bcc, ["hidden@example.com"])
        let text = String(decoding: composed.rawMessage, as: UTF8.self)
        XCTAssertFalse(text.lowercased().contains("hidden@example.com"))
        XCTAssertFalse(text.lowercased().contains("\r\nbcc:"))
        XCTAssertFalse(text.contains("Secret"))
    }

    func testAttachmentsMakeMultipartMixed() throws {
        let file = OutgoingAttachment(filename: "../notes.txt", mimeType: "text/plain", data: Data("notes".utf8))
        let message = MIMEParser.parse(try MessageComposer.compose(draft(), attachments: [file]).rawMessage)
        XCTAssertEqual(message.root.mimeType, "multipart/mixed")
        XCTAssertEqual(message.root.children.first?.mimeType, "multipart/alternative")
        XCTAssertEqual(message.attachments.map(\.filename), ["_notes.txt"])
        XCTAssertEqual(message.attachments.first?.body, Data("notes".utf8))
    }

    func testRefusesWhatCannotBeSentSafely() {
        var noRecipient = draft()
        noRecipient.to = []; noRecipient.cc = []; noRecipient.bcc = []
        XCTAssertThrowsError(try MessageComposer.compose(noRecipient, attachments: [])) { XCTAssertEqual($0 as? ComposeError, .noRecipients) }

        var noSender = draft()
        noSender.from = nil
        XCTAssertThrowsError(try MessageComposer.compose(noSender, attachments: [])) { XCTAssertEqual($0 as? ComposeError, .noSender) }

        for bad in ["kim", "kim@", "@example.org", "a b@example.org", "kim@example.org>\r\nRCPT TO:<x@example.org",
                    "kim@example.org\nBcc: x@example.org", "a@b@example.org", "kim@.example.org", "<kim@example.org>"] {
            var invalid = draft()
            invalid.to = [MailAddress(address: bad)]
            XCTAssertThrowsError(try MessageComposer.compose(invalid, attachments: []), bad.debugDescription) {
                XCTAssertEqual($0 as? ComposeError, .invalidAddress(bad.trimmingCharacters(in: .whitespaces)))
            }
        }
    }

    /// A display name with a line break must not start a header of its own.
    func testNamesAndSubjectsCannotInjectHeaders() throws {
        var hostile = draft()
        hostile.to = [MailAddress(name: "Kim\nBcc: leak@example.com", address: "kim@example.org")]
        hostile.cc = [MailAddress(name: "Lee\r\nX-Injected: 1", address: "lee@example.com")]
        hostile.subject = "Hi\r\nBcc: leak@example.com"
        hostile.inReplyTo = "a@example.org>\r\nBcc: <leak@example.com"
        hostile.references = ["ok@example.org", "bad\r\nX-Injected: 2@example.org"]
        let composed = try MessageComposer.compose(hostile, attachments: [])
        let message = MIMEParser.parse(composed.rawMessage)
        let names = message.headers.map { $0.name.lowercased() }
        XCTAssertFalse(names.contains("bcc"))
        XCTAssertFalse(names.contains("x-injected"))
        XCTAssertEqual(message.references, ["ok@example.org"])
        XCTAssertEqual(message.inReplyTo, [])
        let lines = String(decoding: composed.rawMessage, as: UTF8.self).components(separatedBy: "\r\n")
        XCTAssertFalse(lines.contains { $0.lowercased().hasPrefix("bcc:") || $0.lowercased().hasPrefix("x-injected:") })
        XCTAssertEqual(message.to.first?.name, "Kim Bcc: leak@example.com", "the line break became a space inside the name")
        XCTAssertEqual(message.to.first?.address, "kim@example.org")
        // A bare line feed anywhere in the header section would become a header line once SMTP
        // turns it into CRLF.
        let header = String(decoding: composed.rawMessage, as: UTF8.self).components(separatedBy: "\r\n\r\n")[0]
        XCTAssertFalse(header.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        XCTAssertFalse(header.replacingOccurrences(of: "\r\n", with: "").contains("\r"))
    }

    func testDuplicateRecipientsAreSentToOnce() throws {
        var duplicated = draft()
        duplicated.to = [MailAddress(address: "kim@example.org"), MailAddress(address: "KIM@example.org")]
        duplicated.bcc = [MailAddress(address: "kim@example.org"), MailAddress(address: "hidden@example.com")]
        let composed = try MessageComposer.compose(duplicated, attachments: [])
        XCTAssertEqual(composed.recipients, ["kim@example.org", "lee@example.com", "hidden@example.com"])
    }
}

final class MarkdownHTMLTests: XCTestCase {
    func testEscapesEverythingTheWriterTyped() {
        let html = MarkdownHTML.fragment("<script>alert(1)</script> & <img src=x onerror=alert(2)> \"q\"")
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("<img"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; &lt;img src=x onerror=alert(2)&gt; &quot;q&quot;"), html)
    }

    func testLinksKeepOnlyWebAndMailSchemes() {
        XCTAssertEqual(MarkdownHTML.inline("[site](https://example.org/a_b_c?x=1&y=2)"),
                       "<a href=\"https://example.org/a_b_c?x=1&amp;y=2\">site</a>")
        XCTAssertEqual(MarkdownHTML.inline("[mail](mailto:kim@example.org)"), "<a href=\"mailto:kim@example.org\">mail</a>")
        XCTAssertEqual(MarkdownHTML.inline("[x](javascript:alert(1))"), "x)")
        XCTAssertEqual(MarkdownHTML.inline("[x](data:text/html,hi)"), "x")
        XCTAssertEqual(MarkdownHTML.inline("[x](https://e.org/\"onmouseover=\"alert(1))"),
                       "<a href=\"https://e.org/&quot;onmouseover=&quot;alert(1\">x</a>)")
        XCTAssertEqual(MarkdownHTML.inline("<https://example.org/?a=1&b=2>"),
                       "<a href=\"https://example.org/?a=1&amp;b=2\">https://example.org/?a=1&amp;b=2</a>")
    }

    func testEmphasisCodeAndEscapes() {
        XCTAssertEqual(MarkdownHTML.inline("**bold** and *it* and _it_ and `a < b` and ~~gone~~"),
                       "<strong>bold</strong> and <em>it</em> and <em>it</em> and <code>a &lt; b</code> and <del>gone</del>")
        XCTAssertEqual(MarkdownHTML.inline("\\*not\\* snake_case_name 2*3*4"), "*not* snake_case_name 2*3*4")
        XCTAssertEqual(MarkdownHTML.inline("C:\\path\\file"), "C:\\path\\file")
    }

    func testBlocksForMail() {
        let html = MarkdownHTML.fragment("""
        # Title
        Line one
        line two

        1. first
        2. second

        > quoted
        > > deeper

        ---
        ```
        <b>code</b>
        ```
        """)
        XCTAssertTrue(html.contains("<h1>Title</h1>"))
        XCTAssertTrue(html.contains("<p>Line one<br>\nline two</p>"), "a line break stays a line break")
        XCTAssertTrue(html.contains("<ol>\n<li>first</li>\n<li>second</li>\n</ol>"))
        XCTAssertTrue(html.contains("<blockquote"))
        XCTAssertEqual(html.components(separatedBy: "<blockquote").count - 1, 2, "nested quote")
        XCTAssertTrue(html.contains("<hr>"))
        XCTAssertTrue(html.contains("<pre><code>&lt;b&gt;code&lt;/b&gt;</code></pre>"))
    }

    func testDeepQuotesStopNesting() {
        let deep = String(repeating: ">", count: 200) + " x"
        let html = MarkdownHTML.fragment(deep)
        XCTAssertEqual(html.components(separatedBy: "<blockquote").count - 1, MarkdownHTML.maximumDepth)
    }
}
