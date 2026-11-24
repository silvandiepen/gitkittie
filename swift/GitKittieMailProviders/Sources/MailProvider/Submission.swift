import Foundation

/// A message ready to submit: the envelope plus the exact bytes, built once and kept with the
/// outbox entry so a retry sends the same Message-ID (Architecture.md, Sending and drafts).
public struct OutgoingMessage: Sendable, Hashable {
    /// The stable Message-ID, without angle brackets. Reconciliation looks for it in Sent.
    public var messageID: String
    /// SMTP MAIL FROM (the account's address).
    public var envelopeFrom: String
    /// SMTP RCPT TO: To, Cc and Bcc. Bcc never appears in `rawMessage`.
    public var recipients: [String]
    /// RFC 5322 message with CRLF line endings.
    public var rawMessage: Data

    public init(messageID: String, envelopeFrom: String, recipients: [String], rawMessage: Data) {
        self.messageID = messageID
        self.envelopeFrom = envelopeFrom
        self.recipients = recipients
        self.rawMessage = rawMessage
    }
}

/// What happened to one submission. Acceptance is not delivery: it only means the submission
/// server took responsibility for the message.
public enum SubmissionOutcome: Sendable, Hashable {
    /// The server accepted the message (SMTP 250 after the end of data).
    case accepted(serverReply: String)
    /// The server certainly does not have the message: the failure came before the end of the
    /// message was sent, or the server refused it. `permanent` means retrying the same message
    /// will fail again (5xx, rejected recipients, a missing capability).
    case notSent(reason: String, permanent: Bool)
    /// The end of the message went out, but no answer came back (connection lost, timeout).
    /// The server may well have accepted it. Never resend automatically: reconcile with the
    /// provider first, and leave the decision to the person if that finds nothing.
    case uncertain(reason: String)
}

/// Submits messages. One call is one SMTP transaction on a fresh connection.
public protocol MailSubmitter: Sendable {
    func submit(_ message: OutgoingMessage) async -> SubmissionOutcome
}

/// What the outbox does after a submission (GKM-014 builds the durable outbox on this).
public enum SubmissionFollowUp: Sendable, Hashable {
    /// Sent. Append a copy to Sent unless the provider saves one itself.
    case markSent(appendSentCopy: Bool)
    /// Try again later with the same bytes and Message-ID.
    case retryLater
    /// Give up and show the reason.
    case failed
    /// Look for the Message-ID at the provider before anything else; no retry until then.
    case reconcile

    public static func after(_ outcome: SubmissionOutcome, providerSavesSentCopy: Bool) -> SubmissionFollowUp {
        switch outcome {
        case .accepted: .markSent(appendSentCopy: !providerSavesSentCopy)
        case .notSent(_, let permanent): permanent ? .failed : .retryLater
        case .uncertain: .reconcile
        }
    }
}

public enum ReconciliationResult: Sendable, Hashable {
    /// The message is at the provider: treat the send as done.
    case found([RemoteMessageID])
    /// Not found. The send stays uncertain; the person decides whether to send again.
    case notFound
}

public enum SendReconciler {
    /// Looks for `messageID` in `folders` (Sent, and for a send to oneself, the inbox).
    ///
    /// Finding it proves the provider took the message. Not finding it proves nothing: the
    /// provider may not keep a Sent copy, or not yet. That is why `notFound` never turns into
    /// an automatic resend.
    public static func reconcile(
        messageID: String,
        in folders: [String],
        session: any MailboxSession
    ) async throws -> ReconciliationResult {
        var found: [RemoteMessageID] = []
        for folder in folders {
            found += try await session.search(messageIDHeader: messageID, in: folder)
        }
        return found.isEmpty ? .notFound : .found(found)
    }
}
