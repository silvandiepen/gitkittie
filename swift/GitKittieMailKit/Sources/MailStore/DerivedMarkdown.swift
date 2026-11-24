import Foundation
import MailCore
import MailHTML

/// An attachment as the Markdown records it: the blob that holds its bytes, and how the sender
/// labelled it. `fileName` is cleaned for display; it is never used as a path.
public struct AttachmentReference: Codable, Hashable, Sendable {
    /// SHA-256 of the decoded bytes; the blob is `Mail/blobs/<blob>`.
    public var blob: String
    public var fileName: String
    public var mediaType: String
    public var size: Int
    public var inline: Bool
    /// The part's Content-ID (no angle brackets), when the HTML refers to it as `cid:`.
    public var contentId: String?

    public init(blob: String, fileName: String, mediaType: String, size: Int, inline: Bool, contentId: String? = nil) {
        self.blob = blob
        self.fileName = fileName
        self.mediaType = mediaType
        self.size = size
        self.inline = inline
        self.contentId = contentId
    }
}

/// The YAML front matter of a message's `.md`. Everything here is derived from the `.eml`,
/// except `id`, `account` and `received`, which the store assigned when the message arrived.
public struct MessageFrontMatter: Codable, Equatable, Sendable {
    public var schema: Int
    public var id: MailMessageID
    public var account: MailAccountID
    public var messageId: String?
    public var inReplyTo: [String]
    public var references: [String]
    public var from: [MailAddress]
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var replyTo: [MailAddress]
    public var subject: String?
    public var date: Date?
    public var received: Date
    /// The original's file name, beside this file.
    public var eml: String
    /// SHA-256 of the original's bytes, so the pair can be checked.
    public var emlSha256: String
    public var emlSize: Int
    public var attachments: [AttachmentReference]

    /// The date a message sorts and files by: its own Date header, or when it arrived.
    public var sortDate: Date { date ?? received }
}

/// Writes and reads the derived Markdown. The front matter is YAML in its JSON-compatible flow
/// form, one key per line (`subject: "Hello"`, `to: [{"address":"a@example.com"}]`), so any
/// YAML reader takes it and the store can read it back exactly, without a YAML dependency.
enum DerivedMarkdown {
    static let schemaVersion = 1

    /// Key order in the file: identity first, then the headers, then the integrity fields.
    private static let keyOrder = ["schema", "id", "account", "messageId", "inReplyTo", "references", "from", "to", "cc",
                                   "replyTo", "subject", "date", "received", "eml", "emlSha256", "emlSize", "attachments"]

    static func render(_ front: MessageFrontMatter, message: ParsedMessage) throws -> String {
        var lines = ["---"]
        let object = try JSONSerialization.jsonObject(with: encoder.encode(front)) as? [String: Any] ?? [:]
        for key in keyOrder {
            let value = object[key] ?? NSNull()
            let json = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
            lines.append("\(key): \(String(decoding: json, as: UTF8.self))")
        }
        lines.append("---")
        lines.append("")

        let subject = oneLine(front.subject).isEmpty ? "(No subject)" : oneLine(front.subject)
        lines.append("# \(subject)")
        lines.append("")
        lines.append("**From:** \(people(front.from))  ")
        if !front.to.isEmpty { lines.append("**To:** \(people(front.to))  ") }
        if !front.cc.isEmpty { lines.append("**Cc:** \(people(front.cc))  ") }
        lines.append("**Date:** \(iso(front.sortDate))")
        lines.append("")
        if let text = message.textBody {
            lines.append(text.trimmingCharacters(in: .newlines))
        } else if let html = message.htmlBody {
            // Text read out of the HTML by the same tokenizer the reader's sanitizer uses: no
            // markup, no URLs, and "<" escaped so no Markdown viewer can render it as HTML.
            let text = HTMLText.plainText(fromHTML: html).replacingOccurrences(of: "<", with: "&lt;")
            if !text.isEmpty { lines.append(text); lines.append("") }
            lines.append("_Converted from the HTML version. The original is in [\(front.eml)](\(front.eml))._")
        } else {
            lines.append("_This message has no text body._")
        }
        if !front.attachments.isEmpty {
            lines.append("")
            lines.append("## Attachments")
            lines.append("")
            for attachment in front.attachments {
                let name = attachment.fileName.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                lines.append("- [\(name)](../../../../../blobs/\(attachment.blob)) — \(attachment.mediaType), \(attachment.size) bytes")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Reads the front matter back. Throws if the file is not one the store wrote.
    static func frontMatter(of markdown: String) throws -> MessageFrontMatter {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).makeIterator()
        guard lines.next() == "---" else { throw MailStoreError.unparseableMessage("Markdown has no front matter") }
        var members: [String] = []
        while let line = lines.next(), line != "---" {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            guard keyOrder.contains(key) else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            members.append("\"\(key)\":\(value)")
        }
        let json = "{" + members.joined(separator: ",") + "}"
        return try decoder.decode(MessageFrontMatter.self, from: Data(json.utf8))
    }

    private static func oneLine(_ text: String?) -> String {
        (text ?? "").components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func people(_ addresses: [MailAddress]) -> String {
        guard !addresses.isEmpty else { return "(unknown)" }
        return addresses.map { address in
            address.name.map { "\(oneLine($0)) <\(address.address)>" } ?? "<\(address.address)>"
        }.joined(separator: ", ")
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
