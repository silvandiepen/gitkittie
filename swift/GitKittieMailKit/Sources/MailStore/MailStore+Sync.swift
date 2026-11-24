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
        try mapping(for: SafePath.component(account.rawValue)).replaceFolders(folders)
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

    /// Saves the provider's flags for stored messages.
    public func setFlags(_ flags: [MailMessageID: MailMessageFlags], account: MailAccountID) throws {
        try mapping(for: SafePath.component(account.rawValue)).setFlags(flags)
    }

    /// The provider's flags as last synced; messages never synced are missing from the result.
    public func flags(of ids: [MailMessageID], account: MailAccountID) throws -> [MailMessageID: MailMessageFlags] {
        try mapping(for: SafePath.component(account.rawValue)).flags(of: ids)
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
        let ids = try mapping(for: SafePath.component(account.rawValue)).localIDs(mailbox: mailbox)
        return try index.summaries(among: ids, account: account, limit: limit, offset: offset)
    }

    /// How many stored messages this device knows to be in `mailbox` at the provider.
    public func messageCount(account: MailAccountID, mailbox: String) throws -> Int {
        try mapping(for: SafePath.component(account.rawValue)).localIDs(mailbox: mailbox).count
    }
}

extension MailIndex {
    /// Summaries for a set of ids, newest first. The ids go through a temporary table, so a
    /// folder of any size works without hitting SQLite's limit on bound values.
    func summaries(among ids: Set<MailMessageID>, account: MailAccountID, limit: Int, offset: Int) throws -> [MessageSummary] {
        guard !ids.isEmpty else { return [] }
        return try database.transaction {
            try database.execute("CREATE TEMP TABLE IF NOT EXISTS selected_ids (local_id TEXT PRIMARY KEY); DELETE FROM selected_ids;")
            let insert = try database.prepare("INSERT OR IGNORE INTO selected_ids (local_id) VALUES (?)")
            for id in ids { try insert.run([.text(id.rawValue)]) }
            let result = try readSummaries(database.prepare("""
                SELECT \(Self.summaryColumns) FROM messages m JOIN selected_ids s ON s.local_id = m.local_id
                WHERE m.account_id = ? ORDER BY m.sort_date DESC, m.local_id LIMIT ? OFFSET ?
                """).bind([.text(account.rawValue), .int(Int64(limit)), .int(Int64(offset))]))
            try database.execute("DELETE FROM selected_ids")
            return result
        }
    }

    /// Drops every message of an account from the index.
    func removeAccount(_ account: MailAccountID) throws {
        try database.transaction {
            try database.prepare("DELETE FROM message_text WHERE local_id IN (SELECT local_id FROM messages WHERE account_id = ?)")
                .run([.text(account.rawValue)])
            try database.prepare("DELETE FROM messages WHERE account_id = ?").run([.text(account.rawValue)])
        }
    }
}
