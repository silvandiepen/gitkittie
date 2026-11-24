import Foundation
import MailCore

/// A message the sync fetched, with where it is at the provider and the provider's flags.
public struct SyncedMessage: Sendable {
    public var eml: Data
    public var remote: RemoteLocation
    public var receivedAt: Date
    public var flags: MailMessageFlags

    public init(eml: Data, remote: RemoteLocation, receivedAt: Date, flags: MailMessageFlags) {
        self.eml = eml
        self.remote = remote
        self.receivedAt = receivedAt
        self.flags = flags
    }
}

/// What ``MailStore/storeSynced(_:account:)`` did with one message.
public enum SyncedOutcome: Equatable, Sendable {
    /// The location was already on record; only its flags were saved.
    case alreadyStored(MailMessageID)
    /// The same bytes were already stored (a move, a copy in a second folder, a UIDVALIDITY
    /// reset): the stored message gained this location.
    case matched(MailMessageID)
    /// Written as a new message.
    case stored(MailMessageID)

    public var id: MailMessageID {
        switch self {
        case .alreadyStored(let id), .matched(let id), .stored(let id): id
        }
    }
}

extension MailStore {
    /// Stores a batch the sync fetched (GKM-011, GKM-035), with the same rules as storing them
    /// one by one: a location on record is never stored twice; a message whose exact bytes are
    /// already stored gets the new location instead of a copy (a Message-ID or fingerprint alone
    /// is only a signal, never enough to merge); everything else is written as new. The new
    /// messages share one journal file, one flush per directory and one transaction per database
    /// (``write(_:account:)``); flags and the downloaded byte count are saved once for the batch.
    /// When it returns, every message in the batch is durable and mapped, so a cursor covering
    /// them may be checkpointed.
    public func storeSynced(_ messages: [SyncedMessage], account: MailAccountID) throws -> [SyncedOutcome] {
        let accountName = try SafePath.component(account.rawValue)
        let mapping = try mapping(for: accountName)
        var outcomes: [SyncedOutcome?] = Array(repeating: nil, count: messages.count)
        var flags: [MailMessageID: MailMessageFlags] = [:]
        var fresh: [(offset: Int, message: NewMessage)] = []
        /// New messages in this batch by content hash: a second copy matches the first.
        var freshByHash: [String: Int] = [:]
        var sameAsFresh: [(offset: Int, of: Int)] = []

        for (offset, message) in messages.enumerated() {
            if let existing = try mapping.localID(at: message.remote) {
                outcomes[offset] = .alreadyStored(existing)
                flags[existing] = message.flags
                continue
            }
            let parsed = try parser.parse(message.eml)
            var matched: MailMessageID?
            for candidate in try index.candidates(account: account, messageID: parsed.messageID, fingerprint: ContentFingerprint.of(parsed)) {
                if let original = try? originalData(of: candidate), original == message.eml {
                    matched = candidate
                    break
                }
            }
            if let matched {
                try record(message.remote, for: matched, account: account)
                outcomes[offset] = .matched(matched)
                flags[matched] = message.flags
                continue
            }
            let hash = Hashing.sha256Hex(message.eml)
            if let first = freshByHash[hash] {
                sameAsFresh.append((offset, first))
                continue
            }
            freshByHash[hash] = offset
            fresh.append((offset, NewMessage(eml: message.eml, parsed: parsed, remote: message.remote, receivedAt: message.receivedAt)))
        }

        let ids = try write(fresh.map(\.message), account: account)
        for (entry, id) in zip(fresh, ids) {
            outcomes[entry.offset] = .stored(id)
            flags[id] = messages[entry.offset].flags
        }
        for (offset, first) in sameAsFresh {
            guard case .stored(let id) = outcomes[first] else { continue }
            try record(messages[offset].remote, for: id, account: account)
            outcomes[offset] = .matched(id)
        }
        if !flags.isEmpty { try setFlags(flags, account: account) }
        let bytes = fresh.reduce(Int64(0)) { $0 + Int64($1.message.eml.count) }
        if bytes > 0 { try addImportedBytes(bytes, account: account) }
        return outcomes.map { $0! }
    }
}
