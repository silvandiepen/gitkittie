import Foundation
import MailCore

/// The seam between the store and a MIME parser. The store needs only what it writes into the
/// Markdown, the index and the blob folder; everything else stays in the untouched `.eml`.
///
/// `BasicMessageParser` implements it now. When GKM-002 settles on a MIME library, an adapter
/// over that library conforms to this protocol and is passed to `MailStore`; nothing else in
/// the store changes. Implementations must be pure: the same bytes give the same result, which
/// is what lets the index be rebuilt from the folder with identical search results.
public protocol MessageParsing: Sendable {
    func parse(_ data: Data) throws -> ParsedMessage
}

/// What the store reads out of a message.
public struct ParsedMessage: Equatable, Sendable {
    /// Message-ID without angle brackets, when there is one.
    public var messageID: String?
    public var inReplyTo: [String]
    public var references: [String]
    public var from: [MailAddress]
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var replyTo: [MailAddress]
    public var subject: String?
    /// The Date header, when present and readable.
    public var date: Date?
    /// The plain-text body, decoded to a Swift string, line endings normalised to `\n`.
    /// `nil` when the message has no plain-text part (HTML-only, say).
    public var textBody: String?
    /// True when the message has an HTML body; the store does not render it (GKM-012 does).
    public var hasHTMLBody: Bool
    public var attachments: [ParsedAttachment]

    public init(messageID: String? = nil, inReplyTo: [String] = [], references: [String] = [],
                from: [MailAddress] = [], to: [MailAddress] = [], cc: [MailAddress] = [], replyTo: [MailAddress] = [],
                subject: String? = nil, date: Date? = nil, textBody: String? = nil, hasHTMLBody: Bool = false,
                attachments: [ParsedAttachment] = []) {
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.from = from
        self.to = to
        self.cc = cc
        self.replyTo = replyTo
        self.subject = subject
        self.date = date
        self.textBody = textBody
        self.hasHTMLBody = hasHTMLBody
        self.attachments = attachments
    }
}

/// An attachment or inline part, decoded. Its file name is as the sender wrote it: untrusted,
/// for display only, never a path.
public struct ParsedAttachment: Equatable, Sendable {
    public var fileName: String?
    public var mediaType: String
    public var isInline: Bool
    public var data: Data

    public init(fileName: String?, mediaType: String, isInline: Bool, data: Data) {
        self.fileName = fileName
        self.mediaType = mediaType
        self.isInline = isInline
        self.data = data
    }
}
