import Foundation

/// What a folder is for, from SPECIAL-USE (RFC 6154) attributes or a well-known name.
public enum FolderRole: String, Sendable, Hashable, Codable, CaseIterable {
    case inbox, sent, drafts, trash, junk, archive, all, flagged
}

/// A folder (IMAP mailbox) as the provider reports it.
public struct RemoteFolder: Sendable, Hashable, Codable {
    /// The provider's own name for it, exactly as sent on the wire (IMAP: modified UTF-7).
    /// This is the folder's identity for sync; it is never shown to people.
    public var id: String
    /// The name split into a readable path (decoded), e.g. ["Projects", "Café"].
    public var path: [String]
    public var role: FolderRole?
    public var isSelectable: Bool
    public var attributes: [String]

    public init(id: String, path: [String], role: FolderRole?, isSelectable: Bool, attributes: [String]) {
        self.id = id
        self.path = path
        self.role = role
        self.isSelectable = isSelectable
        self.attributes = attributes
    }

    public var displayName: String { path.last ?? id }
}

/// Where a message lives at the provider. For IMAP: mailbox + UIDVALIDITY + UID
/// (Architecture.md, Storage and identity). Only valid while the folder's UIDVALIDITY holds.
public struct RemoteMessageID: Sendable, Hashable, Codable, CustomStringConvertible {
    public var folder: String
    public var uidValidity: UInt32
    public var uid: UInt32

    public init(folder: String, uidValidity: UInt32, uid: UInt32) {
        self.folder = folder
        self.uidValidity = uidValidity
        self.uid = uid
    }

    public var description: String { "\(folder);UIDVALIDITY=\(uidValidity);UID=\(uid)" }
}

public struct MessageFlags: Sendable, Hashable, Codable {
    public var seen = false
    public var answered = false
    public var flagged = false
    public var deleted = false
    public var draft = false
    /// Keywords other than the system flags, e.g. `$Junk`, `$Forwarded`.
    public var keywords: Set<String> = []

    public init(seen: Bool = false, answered: Bool = false, flagged: Bool = false,
                deleted: Bool = false, draft: Bool = false, keywords: Set<String> = []) {
        self.seen = seen
        self.answered = answered
        self.flagged = flagged
        self.deleted = deleted
        self.draft = draft
        self.keywords = keywords
    }

    public var isEmpty: Bool { self == MessageFlags() }
}

public enum FlagChange: Sendable, Hashable {
    case add, remove
}

public struct FolderStatus: Sendable, Hashable, Codable {
    public var uidValidity: UInt32
    public var uidNext: UInt32?
    public var messageCount: Int
    /// CONDSTORE (RFC 7162), when the server has it.
    public var highestModSeq: UInt64?

    public init(uidValidity: UInt32, uidNext: UInt32?, messageCount: Int, highestModSeq: UInt64?) {
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.messageCount = messageCount
        self.highestModSeq = highestModSeq
    }
}

/// Where incremental sync of one folder stopped. Device-local state (MAIL-013): it lives in
/// Application Support, never in the mail folder.
public struct SyncCursor: Sendable, Hashable, Codable {
    public var folder: String
    public var uidValidity: UInt32
    /// Every message with a UID up to and including this one has been fetched.
    public var highestFetchedUID: UInt32

    public init(folder: String, uidValidity: UInt32, highestFetchedUID: UInt32) {
        self.folder = folder
        self.uidValidity = uidValidity
        self.highestFetchedUID = highestFetchedUID
    }
}

/// A message's metadata, cheap to fetch for a whole folder.
public struct RemoteMessageSummary: Sendable, Hashable {
    public var id: RemoteMessageID
    public var flags: MessageFlags
    public var size: Int?
    public var internalDate: Date?
    /// The Message-ID header as the server parsed it (ENVELOPE). A reconciliation signal only:
    /// not unique, sometimes missing.
    public var messageIDHeader: String?
    public var subject: String?
    /// The first sender (ENVELOPE From): the display name as the server sent it (it may still be
    /// an RFC 2047 encoded word) and the address.
    public var fromName: String?
    public var fromAddress: String?

    public init(id: RemoteMessageID, flags: MessageFlags, size: Int?, internalDate: Date?,
                messageIDHeader: String?, subject: String?, fromName: String? = nil, fromAddress: String? = nil) {
        self.id = id
        self.flags = flags
        self.size = size
        self.internalDate = internalDate
        self.messageIDHeader = messageIDHeader
        self.subject = subject
        self.fromName = fromName
        self.fromAddress = fromAddress
    }
}

/// One message, byte for byte as the provider stores it (RFC 5322 + MIME). This is what goes
/// into the `.eml` file (MAIL-003).
public struct FetchedMessage: Sendable, Hashable {
    public var summary: RemoteMessageSummary
    public var rawMessage: Data

    public init(summary: RemoteMessageSummary, rawMessage: Data) {
        self.summary = summary
        self.rawMessage = rawMessage
    }
}

/// The result of an incremental sync step for one folder.
public struct FolderChanges: Sendable {
    /// The folder's UIDVALIDITY changed (or this was the first sync): every stored
    /// mailbox/UID mapping for the folder is void. Re-map local messages by Message-ID and
    /// content fingerprint; never assume a UID still means the same message.
    public var isReset: Bool
    public var status: FolderStatus
    /// Messages above the cursor, oldest first.
    public var newMessages: [RemoteMessageSummary]
    /// The cursor to store once the new messages are durably written (checkpoint after
    /// durable writes, Architecture.md, Multi-device sync).
    public var nextCursor: SyncCursor

    public init(isReset: Bool, status: FolderStatus, newMessages: [RemoteMessageSummary], nextCursor: SyncCursor) {
        self.isReset = isReset
        self.status = status
        self.newMessages = newMessages
        self.nextCursor = nextCursor
    }
}

/// What woke a ``MailboxSession/waitForChanges(in:timeout:)``.
public enum MailboxEvent: Sendable, Hashable {
    /// The folder's message count or flags changed: run ``MailboxSession/changes(in:since:)``.
    case changed
    /// Nothing happened before the timeout.
    case timedOut
}

/// What a provider can do, so the sync and UI code can choose without knowing the protocol.
public struct ProviderCapabilities: Sendable, Hashable {
    public var push: Bool              // IMAP IDLE
    public var atomicMove: Bool        // IMAP MOVE
    public var reportsNewIDs: Bool     // UIDPLUS: APPENDUID / COPYUID
    public var changeTracking: Bool    // CONDSTORE / QRESYNC
    public var raw: [String]

    public init(push: Bool, atomicMove: Bool, reportsNewIDs: Bool, changeTracking: Bool, raw: [String]) {
        self.push = push
        self.atomicMove = atomicMove
        self.reportsNewIDs = reportsNewIDs
        self.changeTracking = changeTracking
        self.raw = raw
    }
}
