import Foundation
import MailClassifier
import MailCore

// The cleanup dashboard (GKM-021): what clutters the mailbox, read from the index only, and
// batch actions whose preview is exactly what they do. Decisions MAIL-058..061.
//
// Looking never changes anything: the analysis reads the index and this device's sync state.
// A batch is planned as a preview — every message it changes, with the folder it leaves and the
// folder it goes to, and every message it leaves alone and why — and runs through the action
// journal (MAIL-034) as one batch with one Undo, only after the store has checked, in the same
// step that writes the journal, that each previewed message is still exactly as previewed.

/// A group of messages the dashboard suggests looking at. Every group belongs to one account,
/// so a move has one set of folders to choose from.
public struct CleanupGroupID: Hashable, Sendable, Codable {
    public enum Kind: Hashable, Sendable, Codable {
        /// Bulk mail from one address that is not on a mailing list.
        case sender(String)
        /// One mailing list (List-ID, lowercased, without angle brackets).
        case list(String)
        /// Offers whose end date has passed, or that are older than the offer age.
        case expiredOffers
        /// A recurring digest (same stream, same subject apart from numbers and dates): every
        /// issue but the newest.
        case digest(stream: String, pattern: String)
        /// Messages whose attachments together reach the large-message size.
        case largeMessages
    }

    public var account: MailAccountID
    public var kind: Kind

    public init(account: MailAccountID, kind: Kind) {
        self.account = account
        self.kind = kind
    }
}

/// What the dashboard shows for a group.
public struct CleanupGroup: Identifiable, Hashable, Sendable {
    public var id: CleanupGroupID
    /// A sender's name, a list's name, a digest's subject.
    public var title: String
    /// The address or List-ID beside the title, when there is one.
    public var detail: String?
    public var count: Int
    public var unread: Int
    /// The newest message's date.
    public var lastSeen: Date?
    /// Attachment bytes across the group.
    public var bytes: Int64
    /// The category most of the group lives in.
    public var category: MailCategory?
    /// A few of its messages, newest first, to open and look at.
    public var samples: [MessageSummary]

    /// Share of the group marked read, 0...1: how much of it you open.
    public var readShare: Double { count == 0 ? 0 : Double(count - unread) / Double(count) }
}

/// Messages and unread messages per category in one account.
public struct CleanupComposition: Equatable, Sendable {
    public var account: MailAccountID
    public var total: Int
    public var categories: [MailCategory: CategoryCount]
}

/// The dashboard: read from the index, changes nothing.
public struct CleanupOverview: Sendable {
    public var composition: [CleanupComposition]
    /// Senders and lists by volume.
    public var noisy: [CleanupGroup]
    /// One group per account with old or ended offers.
    public var expiredOffers: [CleanupGroup]
    public var digests: [CleanupGroup]
    /// One group per account with large messages.
    public var largeMessages: [CleanupGroup]
    /// Messages not sorted yet (they count as uncertain and are never suggested).
    public var unclassified: Int
    public var analysedAt: Date
}

/// The thresholds the analysis and the protections use.
public struct CleanupOptions: Hashable, Sendable, Codable {
    /// A message in a conversation active this recently is left alone.
    public var recentDays: Int
    /// An offer this old counts as expired even without an end date (Classification.md,
    /// Retention: promotions, 30 days).
    public var offerAgeDays: Int
    /// Attachments together at least this large make a large message.
    public var largeMessageBytes: Int64
    /// A sender or list needs this many messages to be noisy.
    public var noisyMinimum: Int
    /// Receipts, orders, invoices and bookings are protected unless you include them.
    public var includeTransactions: Bool

    public init(recentDays: Int = 14, offerAgeDays: Int = 30, largeMessageBytes: Int64 = 5_000_000, noisyMinimum: Int = 5,
                includeTransactions: Bool = false) {
        self.recentDays = recentDays
        self.offerAgeDays = offerAgeDays
        self.largeMessageBytes = largeMessageBytes
        self.noisyMinimum = noisyMinimum
        self.includeTransactions = includeTransactions
    }
}

/// What a batch does to each message. Never a permanent delete (MAIL-058).
public enum CleanupOperation: Hashable, Sendable, Codable {
    /// Out of the inbox into the account's archive folder (MAIL-036 chooses it).
    case archive(to: String, createTarget: Bool)
    /// Out of every folder but All Mail and Trash into the account's Trash (MAIL-036).
    case trash(to: String, createTarget: Bool)
    /// Out of the inbox (or the one folder it is in) into a folder of the account.
    case move(to: String)

    public var target: String {
        switch self {
        case .archive(let to, _), .trash(let to, _), .move(let to): to
        }
    }
}

/// Why a message is left out of every batch. Protected mail is never changed by a cleanup.
public enum CleanupProtection: String, Hashable, Sendable, Codable, CaseIterable {
    /// Flagged (starred) at the provider or here.
    case flagged
    /// In one of your spaces (linked to a project, topic or person).
    case inSpace
    /// Not sorted yet, not sure what it is, low confidence, or flagged as suspicious.
    case uncertain
    /// Spam or phishing: Quarantine is never moved at the provider.
    case quarantined
    /// A conversation or account security mail.
    case important
    /// A receipt, order, invoice or booking, unless you include them.
    case transaction
    /// Its conversation had a message recently.
    case recent
    /// You replied in its conversation, or wrote in it.
    case repliedByYou
}

/// Why a group's message is not part of a batch although nothing protects it.
public enum CleanupSkip: String, Hashable, Sendable, Codable {
    /// Archive takes mail out of the inbox; this message is not in it.
    case notInInbox
    case alreadyInTarget
    /// Only on this Mac (imported): there is no provider folder to move it out of.
    case onlyOnThisMac
    /// In several folders and none is the inbox: which one to move it out of is unclear.
    case severalFolders
    /// Only in All Mail: nothing is ever moved or expunged out of All Mail (MAIL-036).
    case onlyInAllMail
}

/// One message in a preview, as it was when the preview was made.
public struct CleanupItem: Identifiable, Hashable, Sendable {
    public var id: MailMessageID { summary.id }
    public var summary: MessageSummary
    /// The journal changes running the batch makes for it, in order. Empty when left out.
    public var changes: [MailChange]
    public var protections: [CleanupProtection]
    public var skip: CleanupSkip?
    /// Why it is in the group, when there is more to say ("Offer ended 30 Nov").
    public var note: String?
    /// What the preview saw: the folders and flags at the provider with open changes laid
    /// over them, and whether it was answered. Running compares this again.
    public var state: State

    public struct State: Hashable, Sendable {
        public var mailboxes: [String]
        public var flagged: Bool
        public var answered: Bool
    }

    public var isIncluded: Bool { protections.isEmpty && skip == nil && !changes.isEmpty }
}

/// The exact scope of a batch: what it changes, what it leaves out and why.
public struct CleanupPreview: Sendable, Identifiable {
    public var id: String
    public var group: CleanupGroupID
    public var operation: CleanupOperation
    public var options: CleanupOptions
    /// What running changes, newest first.
    public var included: [CleanupItem]
    /// In the group but protected.
    public var protected: [CleanupItem]
    /// In the group but not changed by this operation (not in the inbox, already there, …).
    public var skipped: [CleanupItem]
    public var createdAt: Date

    /// Protected messages per reason (a message can have several).
    public var protectionCounts: [CleanupProtection: Int] {
        var counts: [CleanupProtection: Int] = [:]
        for item in protected { for reason in item.protections { counts[reason, default: 0] += 1 } }
        return counts
    }
}

/// What a batch did: one journal batch, undone as one.
public struct CleanupRun: Sendable, Hashable {
    public var batch: MailActionBatch
    /// The messages it changed, in preview order.
    public var messages: [MailMessageID]
}

/// A previewed message that is no longer as previewed.
public struct CleanupDifference: Hashable, Sendable, CustomStringConvertible {
    public enum Change: Hashable, Sendable {
        /// Gone from the store.
        case missing
        /// No longer part of the group (reclassified, a newer issue, …).
        case leftGroup
        /// Now protected, for these reasons.
        case nowProtected([CleanupProtection])
        /// Now skipped (it moved at the provider, …).
        case nowSkipped(CleanupSkip)
        /// Its folders or flags at the provider changed.
        case stateChanged
    }

    public var message: MailMessageID
    public var subject: String?
    public var change: Change

    public var description: String {
        let what: String = switch change {
        case .missing: "is gone"
        case .leftGroup: "is no longer part of this group"
        case .nowProtected(let reasons): "is now protected (\(reasons.map(\.rawValue).joined(separator: ", ")))"
        case .nowSkipped(let skip): "no longer applies (\(skip.rawValue))"
        case .stateChanged: "changed at the provider"
        }
        return "“\(subject ?? "(No subject)")” \(what)"
    }
}

public enum CleanupError: Error, Equatable, CustomStringConvertible {
    /// Between the preview and Run, something changed; nothing ran. Preview again.
    case previewChanged([CleanupDifference])
    /// Nothing left to run after your exclusions.
    case nothingToRun
    /// The journal did not take every change; the batch was undone (should never happen: the
    /// state was checked in the same step).
    case incomplete(expected: Int, applied: Int)

    public var description: String {
        switch self {
        case .previewChanged(let differences):
            let count = differences.count == 1 ? "1 message" : "\(differences.count) messages"
            return "Nothing was changed: \(count) changed since the preview. Look at the new preview and run it again."
        case .nothingToRun: return "Nothing to run: every message is excluded or protected."
        case .incomplete(let expected, let applied):
            return "Nothing was changed: only \(applied) of \(expected) changes could be made, so the batch was undone."
        }
    }
}
