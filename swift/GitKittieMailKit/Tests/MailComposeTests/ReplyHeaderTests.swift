import Foundation
import MailCore
import MailMIME
import MailTestSupport
import XCTest
@testable import MailCompose

/// GKM-013 verification: reply, reply all and forward headers over the synthetic fixtures.
/// The fixtures are addressed to alex.morgan@example.net (expectations.json, context).
final class ReplyHeaderTests: XCTestCase {
    private let alex = MailAddress(name: "Alex Morgan", address: "alex.morgan@example.net")
    private let alias = MailAddress(name: "Alex", address: "alex@example.net")
    private var builder: ReplyBuilder {
        ReplyBuilder(ownAddresses: [alex, alias], account: MailAccountID("acct-1"), timeZone: TimeZone(identifier: "UTC")!)
    }

    private func fixture(_ name: String) throws -> MIMEMessage {
        let url = try XCTUnwrap(MailFixtures.directory?.appendingPathComponent("\(name).eml"))
        return MIMEParser.parse(try Data(contentsOf: url))
    }

    private func crlf(_ text: String) -> MIMEMessage {
        MIMEParser.parse(Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8))
    }

    /// The headers of the bytes that would be sent, parsed back.
    private func sent(_ draft: ComposeDraft, bcc: [MailAddress] = []) throws -> MIMEMessage {
        var draft = draft
        draft.bcc = bcc
        if draft.to.isEmpty && draft.cc.isEmpty { draft.to = [MailAddress(address: "someone@example.org")] }
        return MIMEParser.parse(try MessageComposer.compose(draft, attachments: []).rawMessage)
    }

    func testReplyGoesToTheSenderWithThreadHeadersAndQuote() throws {
        let original = try fixture("conv-colleague-alternative")
        let draft = builder.reply(to: original, mode: .reply)
        XCTAssertEqual(draft.to, [MailAddress(name: "Priya Raman", address: "priya.raman@studio.example.com")])
        XCTAssertEqual(draft.cc, [])
        XCTAssertEqual(draft.from, alex)
        XCTAssertEqual(draft.kind, .reply)
        XCTAssertEqual(draft.subject, "Re: Draft floor plan for the Hollis project")
        XCTAssertEqual(draft.inReplyTo, "pr-hollis-plan-1@studio.example.com")
        XCTAssertEqual(draft.references, ["pr-hollis-plan-1@studio.example.com"])
        XCTAssertTrue(draft.body.contains("On Thu, 19 Nov 2026 at 07:47, Priya Raman \\<priya.raman@studio.example.com\\> wrote:"), draft.body)
        XCTAssertTrue(draft.body.contains("> Hi Alex,\n>\n> Attached is the first draft"), draft.body)
        XCTAssertTrue(draft.attachments.isEmpty, "a reply does not carry the attachments")

        let message = try sent(draft)
        XCTAssertEqual(message.inReplyTo, ["pr-hollis-plan-1@studio.example.com"])
        XCTAssertEqual(message.references, ["pr-hollis-plan-1@studio.example.com"])
        XCTAssertEqual(message.subject, "Re: Draft floor plan for the Hollis project")
    }

    func testReplyAllKeepsEveryRecipientOnceAndNeverMe() throws {
        let original = try fixture("conv-colleague-alternative")
        let draft = builder.reply(to: original, mode: .replyAll)
        XCTAssertEqual(draft.to.map(\.address), ["priya.raman@studio.example.com"])
        XCTAssertEqual(draft.cc, [MailAddress(name: "Tomás Ortega", address: "tomas.ortega@studio.example.com")])
        XCTAssertEqual(draft.kind, .replyAll)

        // A busier message: duplicates in different case, me in To and Cc under both addresses,
        // the sender repeated in Cc.
        let busy = crlf("""
        From: Sam <sam@example.org>
        To: Alex Morgan <ALEX.MORGAN@example.net>, Kim <kim@example.org>, kim@EXAMPLE.org
        Cc: alex@example.net, Sam <sam@example.org>, Lee <lee@example.com>, "Kim K" <Kim@example.org>
        Subject: Plans
        Message-ID: <busy-1@example.org>

        Hello.
        """)
        let all = builder.reply(to: busy, mode: .replyAll)
        XCTAssertEqual(all.to.map(\.address), ["sam@example.org"])
        XCTAssertEqual(all.cc.map(\.address), ["kim@example.org", "lee@example.com"])
        XCTAssertEqual(all.from, alex, "answered from the address it was sent to")

        let message = try sent(all)
        let everyone = (message.to + message.cc).map { $0.address.lowercased() }
        XCTAssertEqual(everyone, ["sam@example.org", "kim@example.org", "lee@example.com"])
        XCTAssertFalse(everyone.contains("alex.morgan@example.net"))
        XCTAssertFalse(everyone.contains("alex@example.net"))
    }

    func testReplyHonoursReplyTo() throws {
        let original = try fixture("phish-reply-to-mismatch-invoice")
        let draft = builder.reply(to: original, mode: .reply)
        // Reply-To is what the sender asked for; the classifier warns about the mismatch
        // separately (GKM-017). The composer shows the address before sending.
        XCTAssertEqual(draft.to.map(\.address), ["payments@larkspur-billing.example.net"])
        let all = builder.reply(to: original, mode: .replyAll)
        XCTAssertEqual(all.to.map(\.address), ["payments@larkspur-billing.example.net"])
        XCTAssertEqual(all.cc, [], "the only other recipient is me")

        let support = builder.reply(to: try fixture("conv-support-reply-en"), mode: .replyAll)
        XCTAssertEqual(support.to.map(\.address), ["support@help.fernway.example.com"], "Reply-To equal to From is one recipient")
    }

    func testReplyExtendsReferencesAndKeepsAnExistingPrefix() throws {
        let original = try fixture("conv-reply-to-campaign")
        let draft = builder.reply(to: original, mode: .reply)
        XCTAssertEqual(draft.subject, "Re: Autumn sale: 30% off all single-origin beans")
        XCTAssertEqual(draft.inReplyTo, "marit-reply-5521@larkspur.example.com")
        XCTAssertEqual(draft.references, ["campaign-autumn-2026@news.larkspur.example.com",
                                          "reply-alex-5520@mail.example.net",
                                          "marit-reply-5521@larkspur.example.com"])

        // German "AW:" is a reply prefix too; an encoded subject decodes first.
        let german = builder.reply(to: try fixture("conv-personal-de-thread"), mode: .reply)
        XCTAssertEqual(german.subject, "Re: Ausflug nach Köln am Wochenende")
        let aw = builder.reply(to: crlf("From: a@example.org\nSubject: AW: Termin\nMessage-ID: <x@example.org>\n\nx"), mode: .reply)
        XCTAssertEqual(aw.subject, "AW: Termin")
    }

    func testOnlyInReplyToSeedsReferences() throws {
        let original = crlf("""
        From: a@example.org
        To: alex.morgan@example.net
        Subject: Re: question
        Message-ID: <two@example.org>
        In-Reply-To: <one@example.net>

        Answer.
        """)
        XCTAssertEqual(builder.reply(to: original, mode: .reply).references, ["one@example.net", "two@example.org"])
    }

    func testLongReferencesKeepTheRootAndTheNewest() throws {
        let ids = (1...30).map { "<id-\($0)@example.org>" }.joined(separator: " ")
        let original = crlf("From: a@example.org\nSubject: long\nMessage-ID: <id-31@example.org>\nReferences: \(ids)\n\nx")
        let references = builder.reply(to: original, mode: .reply).references
        XCTAssertEqual(references.count, ReplyBuilder.maximumReferences)
        XCTAssertEqual(references.first, "id-1@example.org")
        XCTAssertEqual(references.last, "id-31@example.org")
        XCTAssertEqual(references[1], "id-13@example.org")
    }

    func testReplyToMyOwnSentMessageGoesToItsRecipients() throws {
        let mine = crlf("""
        From: Alex Morgan <alex.morgan@example.net>
        To: Lotte <lotte.dekker@example.org>
        Cc: Jonas <jonas.weber@example.com>, alex@example.net
        Subject: Verjaardag
        Message-ID: <mine-1@mail.example.net>

        Komen jullie?
        """)
        let reply = builder.reply(to: mine, mode: .reply)
        XCTAssertEqual(reply.to.map(\.address), ["lotte.dekker@example.org"])
        XCTAssertEqual(reply.cc, [])
        let all = builder.reply(to: mine, mode: .replyAll)
        XCTAssertEqual(all.to.map(\.address), ["lotte.dekker@example.org"])
        XCTAssertEqual(all.cc.map(\.address), ["jonas.weber@example.com"])
    }

    func testIdentityFollowsTheAliasTheMessageWasSentTo() throws {
        let toAlias = crlf("From: a@example.org\nTo: alex@example.net\nSubject: hi\nMessage-ID: <m@example.org>\n\nx")
        XCTAssertEqual(builder.reply(to: toAlias, mode: .reply).from, alias)
        let viaList = crlf("From: a@example.org\nTo: list@example.org\nSubject: hi\nMessage-ID: <m@example.org>\n\nx")
        XCTAssertEqual(builder.reply(to: viaList, mode: .reply).from, alex, "the main address when none matches")
    }

    func testForwardStartsANewConversationWithTheAttachments() throws {
        let original = try fixture("conv-colleague-alternative")
        let (draft, attachments) = builder.forward(original)
        XCTAssertEqual(draft.kind, .forward)
        XCTAssertEqual(draft.subject, "Fwd: Draft floor plan for the Hollis project")
        XCTAssertEqual(draft.to, [])
        XCTAssertEqual(draft.cc, [])
        XCTAssertNil(draft.inReplyTo)
        XCTAssertEqual(draft.references, [])
        XCTAssertTrue(draft.body.contains("---------- Forwarded message ----------"))
        XCTAssertTrue(draft.body.contains("Subject: Draft floor plan for the Hollis project"))
        XCTAssertTrue(draft.body.contains("Attached is the first draft"))
        XCTAssertEqual(attachments.map(\.filename), ["hollis-floor-plan-draft.pdf"])
        XCTAssertEqual(attachments.first?.mimeType, "application/pdf")
        XCTAssertEqual(attachments.first.map { String(decoding: $0.data.prefix(8), as: UTF8.self) }, "%PDF-1.4")

        var addressed = draft
        addressed.to = [MailAddress(address: "tomas.ortega@studio.example.com")]
        let message = MIMEParser.parse(try MessageComposer.compose(addressed, attachments: attachments).rawMessage)
        XCTAssertEqual(message.inReplyTo, [])
        XCTAssertEqual(message.attachments.map(\.filename), ["hollis-floor-plan-draft.pdf"])
        XCTAssertEqual(message.attachments.first?.body, attachments.first?.data)
        XCTAssertEqual(ReplyBuilder.prefixed("FW: x", with: "Fwd:", recognising: ["fwd", "fw"]), "FW: x")
    }

    func testForwardOfAnHTMLOnlyMessageQuotesItsText() throws {
        let original = crlf("""
        From: shop@example.org
        To: alex.morgan@example.net
        Subject: Receipt
        Message-ID: <r@example.org>
        Content-Type: text/html; charset=utf-8

        <html><head><style>p{color:red}</style><script>alert(1)</script></head><body><p>Thanks &amp; bye</p><p>Line<br>two</p></body></html>
        """)
        let body = builder.forward(original).draft.body
        XCTAssertTrue(body.contains("Thanks & bye\nLine\ntwo"), body)
        XCTAssertFalse(body.contains("alert"))
        XCTAssertFalse(body.contains("color:red"))
    }

    /// GKM-013 acceptance: reply all never adds internal tags. The sent headers are exactly
    /// the standard set, whatever the original carried.
    func testRepliesCarryOnlyStandardHeaders() throws {
        let original = crlf("""
        From: Sam <sam@example.org>
        To: alex.morgan@example.net, kim@example.org
        Subject: tagged
        Message-ID: <tag-1@example.org>
        X-GitKittie-Space: work
        X-Mailer: Something
        List-Unsubscribe: <mailto:u@example.org>

        x
        """)
        for mode in [ReplyBuilder.Mode.reply, .replyAll] {
            let message = try sent(builder.reply(to: original, mode: mode), bcc: [MailAddress(address: "hidden@example.com")])
            let names = Set(message.headers.map { $0.name.lowercased() })
            var expected: Set<String> = ["date", "from", "to", "message-id", "in-reply-to", "references", "subject",
                                         "mime-version", "content-type"]
            if mode == .replyAll { expected.insert("cc") }
            XCTAssertEqual(names, expected, "\(mode)")
            XCTAssertFalse(names.contains("bcc"))
            XCTAssertFalse(names.contains { $0.hasPrefix("x-") })
        }
        let forward = try sent(builder.forward(original).draft, bcc: [MailAddress(address: "hidden@example.com")])
        XCTAssertFalse(Set(forward.headers.map { $0.name.lowercased() }).contains { $0.hasPrefix("x-") || $0 == "bcc" })
    }
}
