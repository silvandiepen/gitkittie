import Foundation
import MailCore
import MailMIME

/// The store's parser: MailMIME (GKM-002, MAIL-017), which never throws on hostile input and
/// enforces depth, part and header limits. This adapter only maps its result to what the store
/// keeps, and refuses bytes that are not a message at all (no header fields), so an import of
/// some other file never becomes a "message".
public struct MIMEMessageParser: MessageParsing {
    public var limits: MIMEParser.Limits

    public init(limits: MIMEParser.Limits = MIMEParser.Limits()) {
        self.limits = limits
    }

    public func parse(_ data: Data) throws -> ParsedMessage {
        let message = MIMEParser.parse(data, limits: limits)
        guard !message.headers.fields.isEmpty else { throw MailStoreError.unparseableMessage("no header fields") }
        return Self.map(message)
    }

    /// The mapping, public so the reader can read an embedded message/rfc822 the same way.
    public static func map(_ message: MIMEMessage) -> ParsedMessage {
        let leaves = message.root.leaves
        let attachments = leaves.filter(\.isAttachment).map { part in
            ParsedAttachment(fileName: part.filename, mediaType: part.mimeType.isEmpty ? "application/octet-stream" : part.mimeType,
                             isInline: part.disposition?.value == "inline" || (part.disposition == nil && part.contentID != nil),
                             contentID: part.contentID.flatMap { $0.isEmpty ? nil : $0 }, data: part.body)
        }
        return ParsedMessage(
            messageID: message.messageID,
            inReplyTo: message.inReplyTo,
            references: message.references,
            from: message.from,
            to: message.to,
            cc: message.cc,
            replyTo: message.replyTo,
            subject: message.subject.map { $0.trimmingCharacters(in: .whitespaces) },
            date: message.date,
            textBody: message.textBody.map(normaliseLineEndings),
            htmlBody: message.htmlBody,
            attachments: attachments,
            problems: message.problems
        )
    }

    static func normaliseLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
