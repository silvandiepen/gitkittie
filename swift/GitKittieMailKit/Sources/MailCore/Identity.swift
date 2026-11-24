import Foundation

/// A message as GitKittie Mail knows it: a local id, made once when the message first reaches
/// this store and never changed afterwards. Providers renumber, move and duplicate messages;
/// this id is what everything else (Markdown file, index, spaces, notes) points at.
///
/// It is a UUID, scoped to the account the message belongs to (the folder it lives in says
/// which). Message-ID and the content fingerprint are *signals* for reconciliation, never the
/// identity: they can be missing, duplicated or forged. See Architecture.md, Storage and identity.
public struct MailMessageID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    /// A fresh id.
    public init() { self.rawValue = UUID().uuidString.lowercased() }

    /// An id read back from a file name or the index. Only a well-formed UUID is accepted,
    /// so a name that came from outside can never become a path.
    public init?(_ rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        self.rawValue = uuid.uuidString.lowercased()
    }

    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = MailMessageID(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a message id: \(raw)"))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Where a message sits at an IMAP provider: the mailbox, the mailbox's UIDVALIDITY and the
/// message's UID in it. Together they name one message for as long as UIDVALIDITY holds; when
/// the server changes UIDVALIDITY every UID in that mailbox is void (RFC 9051, 2.3.1.1).
public struct RemoteLocation: Hashable, Codable, Sendable {
    public var mailbox: String
    public var uidValidity: UInt32
    public var uid: UInt32

    public init(mailbox: String, uidValidity: UInt32, uid: UInt32) {
        self.mailbox = mailbox
        self.uidValidity = uidValidity
        self.uid = uid
    }
}

/// A mail account as the folder records it: no credentials, ever. Credentials live in the
/// Keychain (GKM-010); this is what the sidebar shows and what the folder is about.
public struct MailAccount: Hashable, Codable, Sendable, Identifiable {
    public var id: MailAccountID
    public var displayName: String
    public var address: String

    public init(id: MailAccountID = MailAccountID(), displayName: String, address: String) {
        self.id = id
        self.displayName = displayName
        self.address = address
    }
}

extension MailAddress {
    /// The name when there is one, the address otherwise.
    public var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return address
    }
}
