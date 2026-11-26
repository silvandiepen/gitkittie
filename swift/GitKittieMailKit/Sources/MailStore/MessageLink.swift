import CryptoKit
import Foundation
import MailCore

/// A link to one message that outlives this device's copy of it (GKM-033, MAIL-131):
///
///     gitkittie-mail://message/<account-id>/m-<sha256 of the Message-ID, hex>
///     gitkittie-mail://message/<account-id>/f-<content fingerprint, hex>   (no Message-ID)
///
/// It goes where the person puts it — a Tasks card, which lives in a Git repository, a note,
/// a chat — so it names the message without saying anything about it: the Message-ID is
/// hashed (it often carries the sender's host name and a time), and nothing else from the
/// message is in it. It does not use the local id, which is made per device and again when
/// mail is downloaded afresh; the Message-ID and the fingerprint come from the message itself,
/// so a resync, an index rebuild or a second download of the same mail finds it again.
///
/// The account says where to look first; a link whose account is gone (removed and added
/// again, or another device until accounts are mapped, GKM-026) is looked up in every account.
public struct MessageLink: Hashable, Sendable, CustomStringConvertible {
    public static let scheme = "gitkittie-mail"
    public static let host = "message"

    public enum Key: Hashable, Sendable {
        /// SHA-256 of the message's Message-ID as the index holds it, lowercase hex.
        case messageID(String)
        /// The index's content fingerprint (`ContentFingerprint`, itself SHA-256), for a
        /// message without a Message-ID.
        case content(String)

        var text: String {
            switch self {
            case .messageID(let hash): "m-" + hash
            case .content(let fingerprint): "f-" + fingerprint
            }
        }

        init?(_ text: String) {
            let lowered = text.lowercased()
            let value = String(lowered.dropFirst(2))
            guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
            if lowered.hasPrefix("m-") { self = .messageID(value) }
            else if lowered.hasPrefix("f-") { self = .content(value) }
            else { return nil }
        }
    }

    public var account: MailAccountID
    public var key: Key

    public init(account: MailAccountID, key: Key) {
        self.account = account
        self.key = key
    }

    /// The link for a message with this Message-ID (as the index and front matter hold it)
    /// or, without one, this content fingerprint.
    public init(account: MailAccountID, messageID: String?, fingerprint: String) {
        if let messageID, !messageID.isEmpty {
            self.init(account: account, key: .messageID(Self.hash(messageID)))
        } else {
            self.init(account: account, key: .content(fingerprint.lowercased()))
        }
    }

    /// The link a URL carries; `nil` for anything else. The account must look like an account
    /// id (letters, digits, `-`, at most 64), so nothing from outside reaches a query or a path
    /// unchecked.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == Self.host else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2, let key = Key(parts[1]) else { return nil }
        let account = parts[0].lowercased()
        guard (1...64).contains(account.count),
              account.unicodeScalars.allSatisfy({ CharacterSet.lowercaseLetters.contains($0) && $0.isASCII
                  || CharacterSet.decimalDigits.contains($0) && $0.isASCII || $0 == "-" }) else { return nil }
        self.init(account: MailAccountID(account), key: key)
    }

    public var url: URL {
        URL(string: "\(Self.scheme)://\(Self.host)/\(account.rawValue)/\(key.text)")!
    }

    public var description: String { url.absoluteString }

    /// SHA-256 of a Message-ID, lowercase hex. Written out by hand: the lookup hashes every
    /// Message-ID of an account, and `String(format:)` per byte is slow at that count.
    static func hash(_ messageID: String) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var hex = [UInt8]()
        hex.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(messageID.utf8)) {
            hex.append(digits[Int(byte >> 4)])
            hex.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: hex, as: UTF8.self)
    }
}

extension MailStore {
    /// The stable link to a stored message (GKM-033); `nil` when it is not in the index.
    public func link(to id: MailMessageID) throws -> MessageLink? {
        try index.linkFields(of: id).map { MessageLink(account: $0.account, messageID: $0.messageID, fingerprint: $0.fingerprint) }
    }

    /// The message a link names: in the link's account first, then in any account. When more
    /// than one copy matches (the same message in two accounts, or a provider's duplicate),
    /// the oldest wins, so a link always opens the same one. `nil` when no stored message
    /// matches: it was deleted here, or is outside what this device downloaded.
    public func resolve(_ link: MessageLink) throws -> MailMessageID? {
        if let found = try index.resolve(link, inAccount: link.account) { return found }
        return try index.resolve(link, inAccount: nil)
    }
}

extension MailIndex {
    func linkFields(of id: MailMessageID) throws -> (account: MailAccountID, messageID: String?, fingerprint: String)? {
        let statement = try database.prepare("SELECT account_id, message_id, fingerprint FROM messages WHERE local_id = ?")
            .bind([.text(id.rawValue)])
        guard try statement.step(), let account = statement.text(0), let fingerprint = statement.text(2) else { return nil }
        return (MailAccountID(account), statement.text(1), fingerprint)
    }

    /// A message the link names, in one account or (with `nil`) in all, oldest first.
    func resolve(_ link: MessageLink, inAccount account: MailAccountID?) throws -> MailMessageID? {
        let scope = account == nil ? "" : "account_id = ? AND "
        let accountValue: [SQLiteValue] = account.map { [.text($0.rawValue)] } ?? []
        switch link.key {
        case .content(let fingerprint):
            // `messages_by_fingerprint` is (account_id, fingerprint): exact in one account.
            let statement = try database.prepare("""
                SELECT local_id FROM messages WHERE \(scope)fingerprint = ? ORDER BY sort_date, local_id LIMIT 1
                """).bind(accountValue + [.text(fingerprint)])
            return try statement.step() ? statement.text(0).flatMap(MailMessageID.init) : nil
        case .messageID(let hash):
            // Only the hash is in the link, so every Message-ID in scope is hashed and compared.
            let statement = try database.prepare("""
                SELECT local_id, message_id FROM messages WHERE \(scope)message_id IS NOT NULL ORDER BY sort_date, local_id
                """).bind(accountValue)
            while try statement.step() {
                guard let messageID = statement.text(1), MessageLink.hash(messageID) == hash else { continue }
                return statement.text(0).flatMap(MailMessageID.init)
            }
            return nil
        }
    }
}
