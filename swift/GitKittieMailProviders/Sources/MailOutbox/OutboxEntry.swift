import Foundation
import MailCompose
import MailCore

/// One send's identity, made when the person presses Send. It names the journal folder, so
/// only a well-formed UUID is accepted.
public struct OperationID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
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
        guard let id = OperationID(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an operation id: \(raw)"))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Where a send is (Architecture.md, Sending and drafts; ThreatModel.md §6).
///
///     queued ──▶ sending ──▶ sent
///       ▲  │        │ └────▶ failed ──(Retry)──▶ queued
///       │  │        └──────▶ uncertain ──(found in Sent)──▶ sent
///       │  │                     └──(Send Again, after a fresh check finds nothing)──▶ queued
///       └──┴── temporary failure, with backoff
///
/// `sending` is written to disk before the first byte goes out. Finding it on disk after a
/// relaunch means the app stopped mid-send: that becomes `uncertain`, never `queued`.
public enum OutboxState: String, Codable, Sendable, Hashable, CaseIterable {
    case queued, sending, sent, failed, uncertain
}

/// What happened to the copy in the Sent folder after a send.
public enum SentCopyState: String, Codable, Sendable, Hashable {
    /// Not dealt with yet.
    case pending
    /// The provider files it itself (or was found to have done so).
    case filedByProvider
    /// The outbox appended it.
    case appended
    /// It was already in Sent when the outbox looked (after a crash between append and record).
    case alreadyThere
    /// The account keeps no copy.
    case notKept
}

public struct OutboxTransition: Codable, Sendable, Hashable {
    public var state: OutboxState
    public var at: Date
    public var note: String?
}

/// One send in the journal (`<Application Support>/Mail/state/outbox/<operation-id>/entry.json`,
/// next to the exact bytes in `message.eml`). Everything here was fixed when Send was pressed:
/// later edits to the draft or the account never change it (ThreatModel.md §6).
public struct OutboxEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: OperationID
    public var account: MailAccountID
    /// The stable Message-ID, without angle brackets. A resend uses it again.
    public var messageID: String
    public var envelopeFrom: String
    public var recipients: [String]
    /// The Bcc recipients among `recipients`, for this device's display only.
    public var bcc: [String]
    /// For the outbox view.
    public var subject: String
    public var visibleRecipients: [String]
    /// The draft as it was sent, so Cancel can put it back.
    public var draft: ComposeDraft?

    public var state: OutboxState
    /// SMTP transactions started for this message.
    public var attempts: Int
    /// When the next automatic step is due (a retry after a temporary failure, a Sent copy
    /// check). Nil: nothing automatic.
    public var nextAttemptAt: Date?
    /// The last problem, in words, for the outbox view.
    public var lastError: String?
    public var sentCopy: SentCopyState
    public var sentAt: Date?
    /// The last time an uncertain send was looked for at the provider.
    public var lastReconciledAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var history: [OutboxTransition]

    /// The person can press Retry (a failed send), Send Again (an uncertain one, after a check)
    /// or Cancel (anything not in flight and not sent).
    public var canRetry: Bool { state == .failed }
    public var canSendAgain: Bool { state == .uncertain }
    public var canCancel: Bool { state == .queued || state == .failed || state == .uncertain }

    /// Done: sent, and its Sent copy dealt with.
    public var isComplete: Bool { state == .sent && sentCopy != .pending }
}
