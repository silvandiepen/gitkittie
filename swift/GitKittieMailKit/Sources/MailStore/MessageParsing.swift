import Foundation
import MailCore

/// The seam between the store and a MIME parser. The store needs only what it writes into the
/// Markdown, the index and the blob folder; everything else stays in the untouched `.eml`.
///
/// `MIMEMessageParser` (over MailMIME, GKM-002) is the implementation. Implementations must be
/// pure: the same bytes give the same result, which is what lets the index be rebuilt from the
/// folder with identical search results.
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
    /// The HTML body as the sender wrote it: hostile until sanitized (MailHTML). Never rendered
    /// as is, never written to the Markdown.
    public var htmlBody: String?
    public var attachments: [ParsedAttachment]
    /// What was malformed and how the parser recovered; empty for a clean message.
    public var problems: [String]
    /// The top-level header fields in order, unfolded and RFC 2047 decoded: what the classifier
    /// reads (List-ID, Authentication-Results, …). Attacker-written; signals, never proof.
    public var headers: [ParsedHeader]
    /// True when an attachment's name had to be rewritten to be safe (a path, control characters).
    public var hasUnsafeAttachmentNames: Bool

    public var hasHTMLBody: Bool { htmlBody != nil }

    public init(messageID: String? = nil, inReplyTo: [String] = [], references: [String] = [],
                from: [MailAddress] = [], to: [MailAddress] = [], cc: [MailAddress] = [], replyTo: [MailAddress] = [],
                subject: String? = nil, date: Date? = nil, textBody: String? = nil, htmlBody: String? = nil,
                attachments: [ParsedAttachment] = [], problems: [String] = [], headers: [ParsedHeader] = [],
                hasUnsafeAttachmentNames: Bool = false) {
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
        self.htmlBody = htmlBody
        self.attachments = attachments
        self.problems = problems
        self.headers = headers
        self.hasUnsafeAttachmentNames = hasUnsafeAttachmentNames
    }
}

/// One header field of a parsed message.
public struct ParsedHeader: Equatable, Sendable {
    public var name: String
    public var value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// An attachment or inline part, decoded. Its file name is as the sender wrote it: untrusted,
/// for display only, never a path.
public struct ParsedAttachment: Equatable, Sendable {
    public var fileName: String?
    public var mediaType: String
    public var isInline: Bool
    /// The Content-ID without angle brackets: what `cid:` references in the HTML point at.
    public var contentID: String?
    public var data: Data

    public init(fileName: String?, mediaType: String, isInline: Bool, contentID: String? = nil, data: Data) {
        self.fileName = fileName
        self.mediaType = mediaType
        self.isInline = isInline
        self.contentID = contentID
        self.data = data
    }
}
