import Foundation
import MailCore

// What the sync coordinator (GKM-011, swift/GitKittieMailProviders MailSync) keeps per device:
// the provider's folder list with a cursor per folder, the provider's flags, and how much
// history it has downloaded. All of it lives in `state/<account-id>/sync.sqlite` beside the
// remote mapping (MAIL-013, MAIL-020); none of it is in the mail folder.

extension MailStore {
    private static let importedBytesCounter = "imported_bytes"

    /// The provider's folders as the last sync saw them, in the provider's order.
    public func syncedFolders(account: MailAccountID) throws -> [SyncedFolder] {
        try mapping(for: SafePath.component(account.rawValue)).folders()
    }

    /// Records the provider's current folder list, keeping each known folder's cursor. A folder
    /// that is gone at the provider is dropped with every location in it; its messages stay
    /// in the mail folder. Returns the removed folder names.
    @discardableResult
    public func replaceSyncedFolders(_ folders: [SyncedFolder], account: MailAccountID) throws -> [String] {
        let removed = try mapping(for: SafePath.component(account.rawValue)).replaceFolders(folders)
        // The index's folder memberships follow the mapping.
        for name in removed { try index.setMembers([], ofMailbox: name, account: account) }
        return removed
    }

    /// Checkpoints a folder's cursor. Call it only after the messages it covers are stored:
    /// `ingest` returns once the `.eml` and the mapping are durable, so after it is safe.
    public func saveCursor(folder: String, uidValidity: UInt32, highestUID: UInt32, historyComplete: Bool,
                           serverCount: Int, account: MailAccountID) throws {
        try mapping(for: SafePath.component(account.rawValue))
            .saveCursor(folder: folder, uidValidity: uidValidity, highestUID: highestUID,
                        historyComplete: historyComplete, serverCount: serverCount)
    }

    /// The UIDs on record for a mailbox at one UIDVALIDITY, with their local ids. This is the
    /// exact set of what is stored: the sync compares it with the provider's UIDs to find what
    /// is missing and what was expunged.
    public func knownUIDs(mailbox: String, uidValidity: UInt32, account: MailAccountID) throws -> [UInt32: MailMessageID] {
        try mapping(for: SafePath.component(account.rawValue)).uids(mailbox: mailbox, uidValidity: uidValidity)
    }

    /// Saves the provider's flags for stored messages, and the read and flagged state the list
    /// and search show (the same `flags` table as ``setFlags(_:for:)``).
    public func setFlags(_ flags: [MailMessageID: MailMessageFlags], account: MailAccountID) throws {
        try mapping(for: SafePath.component(account.rawValue)).setSyncFlags(flags)
        for (id, flag) in flags { try index.setFlags(MessageFlags(seen: flag.seen, flagged: flag.flagged), for: id) }
    }

    /// The provider's flags as last synced; messages never synced are missing from the result.
    public func flags(of ids: [MailMessageID], account: MailAccountID) throws -> [MailMessageID: MailMessageFlags] {
        try mapping(for: SafePath.component(account.rawValue)).syncFlags(of: ids)
    }

    /// Bytes of mail the sync has downloaded for the account, for the storage budget.
    public func importedBytes(account: MailAccountID) throws -> Int64 {
        try mapping(for: SafePath.component(account.rawValue)).counter(Self.importedBytesCounter)
    }

    public func addImportedBytes(_ bytes: Int64, account: MailAccountID) throws {
        try mapping(for: SafePath.component(account.rawValue)).add(bytes, to: Self.importedBytesCounter)
    }

    /// Newest first, only messages this device knows to be in `mailbox` at the provider.
    public func summaries(account: MailAccountID, mailbox: String, limit: Int = 200, offset: Int = 0) throws -> [MessageSummary] {
        try index.summaries(matching: SearchQuery(account: account, mailbox: mailbox), limit: limit, offset: offset)
    }

    /// How many stored messages this device knows to be in `mailbox` at the provider.
    public func messageCount(account: MailAccountID, mailbox: String) throws -> Int {
        try mapping(for: SafePath.component(account.rawValue)).localIDs(mailbox: mailbox).count
    }
}

extension MailIndex {
    /// Drops every message of an account from the index, with everything that hangs off it.
    func removeAccount(_ account: MailAccountID) throws {
        while true {
            let page = try summaries(account: account, limit: 500, offset: 0)
            if page.isEmpty { return }
            for summary in page { try remove(summary.id) }
        }
    }
}
