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
        let mapping = try mapping(for: SafePath.component(account.rawValue))
        let removed = try mapping.replaceFolders(folders)
        // The index's folder memberships follow the mapping.
        for name in removed {
            try index.setMembers([], ofMailbox: name, account: account)
            try reapplyOverlay(account: account, mapping: mapping, touching: name)
        }
        try refreshTrashAndJunk(account: account)
        return removed
    }

    // MARK: Trash and Junk (MAIL-102)

    /// An account's Trash and Junk, by folder name, from its folders' roles: the folders whose
    /// mail shows only there. Without a `trash` folder, the `Trash` folder an action creates on
    /// first use counts (MAIL-036), so mail moved there leaves the other views before the next
    /// folder list names it; likewise without a `junk` folder, the `Junk` folder an Always Junk
    /// rule creates on first use (GKM-072, MAIL-110).
    public static func trashAndJunkFolders(_ folders: [SyncedFolder]) -> [String: String] {
        var result: [String: String] = [:]
        for folder in folders {
            if let role = folder.role, role == "trash" || role == "junk" { result[folder.name] = role }
        }
        if !folders.isEmpty, !result.values.contains("trash"), folders.first(where: { $0.name == "Trash" })?.role == nil {
            result["Trash"] = "trash"
        }
        if !folders.isEmpty, !result.values.contains("junk"), folders.first(where: { $0.name == "Junk" })?.role == nil {
            result["Junk"] = "junk"
        }
        return result
    }

    /// Copies the account's Trash and Junk (from the roles on record in its sync state) into
    /// the index, which then leaves the mail only there out of every other view. Runs when the
    /// sync records the provider's folders and when the store opens; call it after anything
    /// else that changes a folder's role.
    public func refreshTrashAndJunk(account: MailAccountID) throws {
        let folders = try mapping(for: SafePath.component(account.rawValue)).folders()
        try index.setTrashAndJunkMailboxes(Self.trashAndJunkFolders(folders), account: account)
    }

    /// True when every folder the message is in is its account's Trash or Junk.
    public func isOnlyInTrashOrJunk(_ id: MailMessageID) throws -> Bool {
        try index.isTrashOrJunk(id)
    }

    /// Applies an account's folder choices (MAIL-094) to the folders on record at once, without
    /// waiting for the next sync: each folder's role in use is worked out again from its detected
    /// role. Returns the folders as they are now.
    @discardableResult
    public func applyMailboxSettings(_ settings: MailboxSettings, account: MailAccountID) throws -> [SyncedFolder] {
        let mapping = try mapping(for: SafePath.component(account.rawValue))
        let folders = try mapping.folders()
        let roles = settings.effectiveRoles(detected: folders.map { ($0.name, $0.detectedRole) })
        try mapping.setRoles(roles)
        // A chosen Trash or Junk leaves the other views at once (MAIL-102).
        try refreshTrashAndJunk(account: account)
        return try mapping.folders()
    }

    /// Follows a folder renamed at the provider (GKM-066), with the folders inside it: the sync
    /// state, the locations, the action journal and the index's folder memberships move to the
    /// new name, so the mail in it is not downloaded again. Call it only after the provider
    /// renamed the folder, and while the account's sync is stopped.
    public func renameSyncedFolder(_ old: String, to new: String, delimiter: Character?, account: MailAccountID) throws {
        let mapping = try mapping(for: SafePath.component(account.rawValue))
        let renamed = try mapping.renameFolder(old, to: new, delimiter: delimiter)
        for pair in renamed {
            try index.renameMailbox(pair.old, to: pair.new, account: account)
        }
        // A renamed Trash or Junk keeps its mail out of the other views (MAIL-102).
        try refreshTrashAndJunk(account: account)
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
    ///
    /// Open changes made here (GKM-015) stay laid over them, unless the provider changed the same
    /// flag after this device last saw it: then the provider wins (MAIL-035).
    public func setFlags(_ flags: [MailMessageID: MailMessageFlags], account: MailAccountID) throws {
        let mapping = try mapping(for: SafePath.component(account.rawValue))
        try mapping.setSyncFlags(flags)
        try reconcileFlagRows(with: flags, mapping: mapping, now: Date())
        // One commit for the lot, not one per message (GKM-035).
        try index.batch {
            for id in flags.keys.sorted() {
                try index.setFlags(effectiveState(of: id, mapping: mapping).flags, for: id)
            }
        }
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
            if page.isEmpty { break }
            for summary in page { try remove(summary.id) }
        }
        try setTrashAndJunkMailboxes([:], account: account)
    }
}
