import Foundation

/// Small synthetic messages for the store tests, written here until the GKM-003 corpus lands.
/// Every address is on a reserved domain (example.com, example.org, example.net).
enum SyntheticMail {
    static func plain(from: String = "Ada Example <ada@example.com>", to: String = "bo@example.org",
                      subject: String, date: String = "Tue, 24 Nov 2026 10:15:00 +0100",
                      messageID: String? = nil, inReplyTo: String? = nil, references: String? = nil,
                      body: String, extraHeaders: [String] = []) -> Data {
        var headers = ["From: \(from)", "To: \(to)", "Subject: \(subject)", "Date: \(date)"]
        if let messageID { headers.append("Message-ID: <\(messageID)>") }
        if let inReplyTo { headers.append("In-Reply-To: <\(inReplyTo)>") }
        if let references { headers.append("References: \(references)") }
        headers += extraHeaders
        headers += ["MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: 8bit"]
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + body.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n").utf8)
    }

    static func withAttachment(subject: String, messageID: String, body: String,
                               fileName: String, attachment: Data, mediaType: String = "application/pdf",
                               date: String = "Wed, 25 Nov 2026 08:00:00 +0000") -> Data {
        let boundary = "=_synthetic_boundary_42"
        let base64 = attachment.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let text = """
        From: Cy Example <cy@example.net>\r
        To: ada@example.com\r
        Subject: \(subject)\r
        Date: \(date)\r
        Message-ID: <\(messageID)>\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="\(boundary)"\r
        \r
        This is a multi-part message in MIME format.\r
        --\(boundary)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        \(body)\r
        --\(boundary)\r
        Content-Type: \(mediaType); name="\(fileName)"\r
        Content-Disposition: attachment; filename="\(fileName)"\r
        Content-Transfer-Encoding: base64\r
        \r
        \(base64)\r
        --\(boundary)--\r
        """
        return Data(text.utf8)
    }

    /// A handful of varied messages with overlapping words, so search has something to rank.
    static var corpus: [Data] {
        [
            plain(subject: "Invoice 2026-114 for November", messageID: "inv-114@example.com",
                  body: "Hello Bo,\nThe invoice for November is attached in the portal.\nRegards, Ada"),
            plain(from: "Billing <billing@example.org>", subject: "Your receipt", date: "Mon, 23 Nov 2026 09:00:00 -0500",
                  messageID: "receipt-9@example.org", body: "Thanks for your payment. Receipt number 9. No invoice needed."),
            plain(from: "Bo Example <bo@example.org>", to: "ada@example.com", subject: "Re: Invoice 2026-114 for November",
                  date: "Tue, 24 Nov 2026 12:00:00 +0000", messageID: "re-inv-114@example.org", inReplyTo: "inv-114@example.com",
                  references: "<inv-114@example.com>", body: "Got it, paying the invoice today.\n> The invoice for November"),
            plain(from: "Newsletter <news@example.net>", subject: "Weekly garden news", date: "Sun, 1 Nov 2026 07:30:00 +0000",
                  messageID: "news-44@example.net", body: "Tomatoes, basil and late autumn planting. Unsubscribe any time."),
            plain(from: "\"Doe, Jamie\" <jamie@example.com>", subject: "=?utf-8?q?Caf=C3=A9_on_Friday?=",
                  date: "Fri, 30 Oct 2026 16:45:00 +0200", messageID: "cafe@example.com", body: "Shall we meet at the café on Friday?"),
            plain(subject: "No message id here", date: "Thu, 15 Oct 2026 11:00:00 +0000",
                  body: "A message without a Message-ID still gets a stable local id."),
            withAttachment(subject: "Garden plan", messageID: "plan@example.net", body: "The garden plan is attached=2E",
                           fileName: "plan.pdf", attachment: Data("%PDF-1.4 synthetic garden plan".utf8)),
        ]
    }
}
