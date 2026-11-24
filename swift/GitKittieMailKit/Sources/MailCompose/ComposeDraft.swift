import Foundation
import MailCore

/// A draft's own id: a UUID, made when the draft is first created. Its folder in
/// `Mail/drafts/` is named after it, so only a well-formed UUID is ever accepted.
public struct DraftID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init() { self.rawValue = UUID().uuidString.lowercased() }

    public init?(_ rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        self.rawValue = uuid.uuidString.lowercased()
    }

    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = DraftID(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a draft id: \(raw)"))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// What a draft started as. It decides nothing after creation; the headers it needs
/// (In-Reply-To, References) are on the draft itself.
public enum ComposeKind: String, Codable, Sendable, Hashable {
    case new, reply, replyAll, forward
}

/// A file attached to a draft. The bytes live next to the draft, named by their SHA-256
/// (`Mail/drafts/<draft-id>/attachments/<sha256>`); the name the user sees is only data.
public struct DraftAttachment: Codable, Sendable, Hashable, Identifiable {
    public var id: String { sha256 + "/" + filename }
    public var filename: String
    public var mimeType: String
    public var size: Int
    public var sha256: String

    public init(filename: String, mimeType: String, size: Int, sha256: String) {
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.sha256 = sha256
    }
}

/// A message being written. Saved as JSON in `Mail/drafts/<id>/draft.json`; every save is a new
/// revision, and the revision a save started from decides whether it is an edit or a conflict.
public struct ComposeDraft: Codable, Sendable, Hashable, Identifiable {
    public var id: DraftID
    /// The account it is sent from; nil until one is chosen.
    public var account: MailAccountID?
    /// The identity in From. One of the account's addresses.
    public var from: MailAddress?
    public var to: [MailAddress]
    public var cc: [MailAddress]
    /// Envelope only: never written into the message or the Sent copy.
    public var bcc: [MailAddress]
    public var subject: String
    /// Markdown. Sent as text/plain as written, and as HTML generated from it.
    public var body: String
    public var attachments: [DraftAttachment]
    public var kind: ComposeKind
    /// The Message-ID this replies to, without angle brackets.
    public var inReplyTo: String?
    public var references: [String]
    /// The stored message this draft answers or forwards, for marking it answered later.
    public var source: MailMessageID?
    /// Increases by one with every save. 0 = never saved.
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date
    /// The installation that saved this revision (`StoreLocations.deviceIdentifier()`).
    public var savedBy: String?
    /// Set on a conflict copy: the draft it split from.
    public var conflictOf: DraftID?

    public init(id: DraftID = DraftID(), account: MailAccountID? = nil, from: MailAddress? = nil,
                to: [MailAddress] = [], cc: [MailAddress] = [], bcc: [MailAddress] = [],
                subject: String = "", body: String = "", attachments: [DraftAttachment] = [],
                kind: ComposeKind = .new, inReplyTo: String? = nil, references: [String] = [],
                source: MailMessageID? = nil, revision: Int = 0, createdAt: Date = Date(),
                updatedAt: Date = Date(), savedBy: String? = nil, conflictOf: DraftID? = nil) {
        self.id = id
        self.account = account
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.attachments = attachments
        self.kind = kind
        self.inReplyTo = inReplyTo
        self.references = references
        self.source = source
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.savedBy = savedBy
        self.conflictOf = conflictOf
    }

    /// Everything the person wrote, without the bookkeeping. Two drafts with the same content
    /// need no new revision.
    public var content: Content {
        Content(account: account, from: from, to: to, cc: cc, bcc: bcc, subject: subject, body: body,
                attachments: attachments, kind: kind, inReplyTo: inReplyTo, references: references, source: source)
    }

    public struct Content: Hashable, Sendable {
        var account: MailAccountID?
        var from: MailAddress?
        var to: [MailAddress], cc: [MailAddress], bcc: [MailAddress]
        var subject: String, body: String
        var attachments: [DraftAttachment]
        var kind: ComposeKind
        var inReplyTo: String?
        var references: [String]
        var source: MailMessageID?
    }

    /// True when there is nothing worth keeping: no recipient, subject, text or attachment.
    public var isBlank: Bool {
        to.isEmpty && cc.isEmpty && bcc.isEmpty && attachments.isEmpty
            && subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
