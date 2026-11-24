import Foundation

/// A folder's status and every UID in it, ascending: what the sync compares with what it has
/// stored to find new and expunged messages (GKM-011).
public struct FolderListing: Sendable, Hashable {
    public var status: FolderStatus
    public var uids: [UInt32]

    public init(status: FolderStatus, uids: [UInt32]) {
        self.status = status
        self.uids = uids
    }
}

extension MailProviderError {
    /// True when the connection failed because the server's certificate was not accepted (or
    /// the TLS handshake failed for another reason): not a network outage, and not something a
    /// retry fixes. MailNet reports every TLS failure with a "TLS" prefix.
    public var isTLSFailure: Bool {
        if case .connectionFailed(let reason) = self { return reason.hasPrefix("TLS") }
        return false
    }
}

/// Flags that changed in a folder since a CONDSTORE checkpoint (GKM-015).
public struct FlagChanges: Sendable, Hashable {
    /// The folder's HIGHESTMODSEQ when the changes were read: the next checkpoint.
    public var highestModSeq: UInt64
    public var flags: [RemoteMessageID: MessageFlags]

    public init(highestModSeq: UInt64, flags: [RemoteMessageID: MessageFlags]) {
        self.highestModSeq = highestModSeq
        self.flags = flags
    }
}
