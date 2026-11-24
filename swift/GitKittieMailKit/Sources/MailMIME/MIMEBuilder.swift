import Foundation
import MailCore

/// An attachment to put in an outgoing message.
public struct OutgoingAttachment: Sendable, Hashable {
    public var filename: String
    public var mimeType: String
    public var data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

/// Composes RFC 5322 + MIME messages: CRLF line endings, headers RFC 2047-encoded where needed,
/// file names RFC 2231-encoded, text quoted-printable (or 7bit when plain ASCII with short
/// lines), attachments base64.
public struct MIMEBuilder: Sendable {
    public var from: MailAddress
    public var to: [MailAddress]
    public var cc: [MailAddress]
    /// Envelope only: Bcc never appears in the message itself.
    public var bcc: [MailAddress]
    public var replyTo: [MailAddress]
    public var subject: String
    public var date: Date
    /// Without angle brackets. Generated once per outgoing message and kept across retries.
    public var messageID: String
    public var inReplyTo: String?
    public var references: [String]
    public var textBody: String
    public var htmlBody: String?
    public var attachments: [OutgoingAttachment]
    public var extraHeaders: [(String, String)]

    public init(from: MailAddress, to: [MailAddress], cc: [MailAddress] = [], bcc: [MailAddress] = [],
                replyTo: [MailAddress] = [], subject: String, date: Date = Date(), messageID: String? = nil,
                inReplyTo: String? = nil, references: [String] = [], textBody: String, htmlBody: String? = nil,
                attachments: [OutgoingAttachment] = [], extraHeaders: [(String, String)] = []) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.subject = subject
        self.date = date
        self.messageID = messageID ?? MIMEBuilder.makeMessageID(for: from.address)
        self.inReplyTo = inReplyTo
        self.references = references
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachments = attachments
        self.extraHeaders = extraHeaders
    }

    /// `<random@domain-of-sender>`: random enough to be unique, and it leaks nothing about the
    /// device.
    public static func makeMessageID(for address: String) -> String {
        let domain = address.split(separator: "@").last.map(String.init) ?? "localhost.invalid"
        return "\(UUID().uuidString.lowercased()).\(Int(Date().timeIntervalSince1970))@\(domain)"
    }

    /// Every envelope recipient (To, Cc, Bcc), de-duplicated.
    public var recipients: [String] {
        var seen = Set<String>()
        return (to + cc + bcc).map(\.address).filter { seen.insert($0.lowercased()).inserted }
    }

    public func build() -> Data {
        var out = ""
        func header(_ name: String, _ value: String) {
            out += fold("\(name): \(value)") + "\r\n"
        }
        header("Date", MailDates.format(date))
        header("From", AddressParser.format(from))
        if !to.isEmpty { header("To", to.map(AddressParser.format).joined(separator: ", ")) }
        if !cc.isEmpty { header("Cc", cc.map(AddressParser.format).joined(separator: ", ")) }
        if !replyTo.isEmpty { header("Reply-To", replyTo.map(AddressParser.format).joined(separator: ", ")) }
        header("Message-ID", "<\(messageID)>")
        if let inReplyTo { header("In-Reply-To", "<\(inReplyTo)>") }
        if !references.isEmpty { header("References", references.map { "<\($0)>" }.joined(separator: " ")) }
        header("Subject", EncodedWords.encodeIfNeeded(subject))
        for (name, value) in extraHeaders where Self.isSafeHeaderName(name) {
            header(name, EncodedWords.encodeIfNeeded(value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")))
        }
        header("MIME-Version", "1.0")

        let textEntity = Self.textEntity(textBody, subtype: "plain")
        var body: String
        let content: (headers: String, body: String)
        if let htmlBody {
            content = Self.multipart("alternative", [textEntity, Self.textEntity(htmlBody, subtype: "html")])
        } else {
            content = textEntity
        }
        if attachments.isEmpty {
            out += content.headers
            body = content.body
        } else {
            var parts = [content]
            for attachment in attachments {
                let name = MIMEPart.safeFilename(attachment.filename)
                let headers = "Content-Type: \(attachment.mimeType); " + ParameterizedValue.formatParameter("name", name) + "\r\n"
                    + "Content-Disposition: attachment; " + ParameterizedValue.formatParameter("filename", name) + "\r\n"
                    + "Content-Transfer-Encoding: base64\r\n"
                parts.append((headers, TransferEncoding.encodeBase64Lines(attachment.data)))
            }
            let mixed = Self.multipart("mixed", parts)
            out += mixed.headers
            body = mixed.body
        }
        out += "\r\n" + body
        return Data(out.utf8)
    }

    private static func isSafeHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F && $0 != UInt8(ascii: ":") }
            && !["bcc", "from", "to", "cc", "subject", "message-id", "date", "mime-version", "content-type",
                 "content-transfer-encoding"].contains(name.lowercased())
    }

    static func textEntity(_ text: String, subtype: String) -> (headers: String, body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let isSevenBitSafe = normalized.unicodeScalars.allSatisfy { $0.isASCII }
            && normalized.split(separator: "\n", omittingEmptySubsequences: false).allSatisfy { $0.utf8.count <= 76 && !$0.hasPrefix(".") }
        if isSevenBitSafe {
            let body = normalized.replacingOccurrences(of: "\n", with: "\r\n")
            return ("Content-Type: text/\(subtype); charset=us-ascii\r\nContent-Transfer-Encoding: 7bit\r\n", body)
        }
        return ("Content-Type: text/\(subtype); charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n",
                TransferEncoding.encodeQuotedPrintable(normalized))
    }

    static func multipart(_ subtype: String, _ parts: [(headers: String, body: String)]) -> (headers: String, body: String) {
        let boundary = "=_gkm_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = ""
        for part in parts {
            // The CRLF before each delimiter belongs to the delimiter (RFC 2046 5.1.1), so a
            // body's own trailing line break survives the round trip.
            body += "--\(boundary)\r\n" + part.headers + "\r\n" + part.body + "\r\n"
        }
        body += "--\(boundary)--\r\n"
        return ("Content-Type: multipart/\(subtype); boundary=\"\(boundary)\"\r\n", body)
    }

    /// Folds a header line at whitespace so no line exceeds 78 characters where possible
    /// (RFC 5322 2.2.3). Encoded words already carry their own CRLF+space breaks.
    func fold(_ line: String) -> String {
        var output: [String] = []
        for (index, physical) in line.components(separatedBy: "\r\n").enumerated() {
            var words = physical.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            // A continuation line must start with whitespace, or it would read as a new field.
            if index > 0 {
                while words.first == "" { words.removeFirst() }
                if !words.isEmpty { words[0] = " " + words[0] }
            }
            var current = ""
            for (position, word) in words.enumerated() {
                if position == 0 {
                    current = word
                } else if current.count + 1 + word.count > 78, !current.trimmingCharacters(in: .whitespaces).isEmpty {
                    output.append(current)
                    current = " " + word
                } else {
                    current += " " + word
                }
            }
            output.append(current)
        }
        return output.joined(separator: "\r\n")
    }
}
