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

/// One part of a message's MIME structure as the provider describes it (IMAP BODYSTRUCTURE), so
/// the sync can fetch text first and leave large attachments at the provider (GKM-036).
public struct RemoteBodyPart: Sendable, Hashable {
    /// The IMAP part specifier ("1", "2.1"); "" for the top of a multipart message.
    public var section: String
    /// Lowercased `type/subtype`.
    public var mediaType: String
    public var boundary: String?
    /// Lowercased Content-Transfer-Encoding.
    public var encoding: String?
    /// Encoded size in octets.
    public var size: Int
    public var fileName: String?
    /// Lowercased Content-Disposition.
    public var disposition: String?
    public var contentID: String?
    public var parts: [RemoteBodyPart]

    public init(section: String, mediaType: String, boundary: String? = nil, encoding: String? = nil, size: Int,
                fileName: String? = nil, disposition: String? = nil, contentID: String? = nil, parts: [RemoteBodyPart] = []) {
        self.section = section
        self.mediaType = mediaType.lowercased()
        self.boundary = boundary
        self.encoding = encoding?.lowercased()
        self.size = size
        self.fileName = fileName
        self.disposition = disposition?.lowercased()
        self.contentID = contentID
        self.parts = parts
    }
}
