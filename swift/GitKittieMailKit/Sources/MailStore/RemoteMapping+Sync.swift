import Foundation
import MailCore

/// A folder at the provider as this device last saw it, with where its sync stopped (GKM-011).
/// Device state (MAIL-013, MAIL-020): it lives beside the mapping in `sync.sqlite`, never in the
/// mail folder.
public struct SyncedFolder: Sendable, Hashable, Codable {
    /// The provider's own name for the folder (IMAP: the mailbox name as sent on the wire).
    public var name: String
    /// The readable path, decoded, e.g. ["Projects", "Café"].
    public var path: [String]
    /// What the folder is for (`inbox`, `sent`, …), when the provider says.
    public var role: String?
    /// The UIDVALIDITY the cursor below belongs to; `nil` before the first sync.
    public var uidValidity: UInt32?
    /// Every message with a UID up to and including this one has been imported or is waiting
    /// in the history queue. Checkpointed only after the messages are durably written.
    public var highestUID: UInt32
    /// True once every message the folder had at the last sync is stored here.
    public var historyComplete: Bool
    /// How many messages the provider reported at the last sync.
    public var serverCount: Int

    public init(name: String, path: [String], role: String? = nil, uidValidity: UInt32? = nil,
                highestUID: UInt32 = 0, historyComplete: Bool = false, serverCount: Int = 0) {
        self.name = name
        self.path = path
        self.role = role
        self.uidValidity = uidValidity
        self.highestUID = highestUID
        self.historyComplete = historyComplete
        self.serverCount = serverCount
    }

    public var displayName: String { path.last ?? name }
}

extension RemoteMapping {
    /// Schema 2 → 3 (GKM-011). Also takes a database from before the merge with GKM-012, whose
    /// version 2 had the sync tables and a `message_flags` table instead of `flags`: nothing
    /// shipped with it, but a development machine may have one.
    func migrateToSyncState() throws {
        func tableExists(_ name: String) throws -> Bool {
            try database.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").bind([.text(name)]).step()
        }
        func columnExists(_ column: String, in table: String) throws -> Bool {
            let statement = try database.prepare("SELECT 1 FROM pragma_table_info(?) WHERE name = ?").bind([.text(table), .text(column)])
            return try statement.step()
        }
        try database.execute("CREATE TABLE IF NOT EXISTS flags (local_id TEXT PRIMARY KEY, seen INTEGER NOT NULL, flagged INTEGER NOT NULL)")
        if try !columnExists("answered", in: "flags") {
            try database.execute("""
                ALTER TABLE flags ADD COLUMN answered INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE flags ADD COLUMN draft INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE flags ADD COLUMN keywords TEXT NOT NULL DEFAULT '';
                """)
        }
        if try tableExists("message_flags") {
            try database.execute("""
                INSERT OR REPLACE INTO flags (local_id, seen, flagged, answered, draft, keywords)
                  SELECT local_id, seen, flagged, answered, draft, keywords FROM message_flags;
                DROP TABLE message_flags;
                """)
        }
        try database.execute("""
            CREATE TABLE IF NOT EXISTS folder_state (
              name TEXT PRIMARY KEY, path TEXT NOT NULL, role TEXT, position INTEGER NOT NULL,
              uid_validity INTEGER, highest_uid INTEGER NOT NULL DEFAULT 0,
              history_complete INTEGER NOT NULL DEFAULT 0, server_count INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS counters (name TEXT PRIMARY KEY, value INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS locations_by_mailbox ON locations (mailbox, uid_validity, uid);
            """)
    }

    // MARK: Folders and cursors

    func folders() throws -> [SyncedFolder] {
        let statement = try database.prepare("""
            SELECT name, path, role, uid_validity, highest_uid, history_complete, server_count
            FROM folder_state ORDER BY position, name
            """)
        var result: [SyncedFolder] = []
        while try statement.step() {
            guard let name = statement.text(0) else { continue }
            let path = statement.text(1).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [name]
            result.append(SyncedFolder(
                name: name, path: path, role: statement.text(2),
                uidValidity: statement.isNull(3) ? nil : UInt32(statement.int(3)),
                highestUID: UInt32(statement.int(4)), historyComplete: statement.int(5) != 0,
                serverCount: statement.int(6)))
        }
        return result
    }

    /// Records the provider's folder list, in its order, keeping each known folder's cursor.
    /// Folders that are gone at the provider lose their row and every location in them; their
    /// messages stay in the mail folder. Returns the names that were removed.
    func replaceFolders(_ folders: [SyncedFolder]) throws -> [String] {
        try database.transaction {
            let wanted = Set(folders.map(\.name))
            let removed = try self.folders().map(\.name).filter { !wanted.contains($0) }
            for name in removed {
                try database.prepare("DELETE FROM folder_state WHERE name = ?").run([.text(name)])
                try database.prepare("DELETE FROM locations WHERE mailbox = ?").run([.text(name)])
                try database.prepare("DELETE FROM mailboxes WHERE name = ?").run([.text(name)])
            }
            for (position, folder) in folders.enumerated() {
                let path = String(decoding: try JSONEncoder().encode(folder.path), as: UTF8.self)
                try database.prepare("""
                    INSERT INTO folder_state (name, path, role, position) VALUES (?, ?, ?, ?)
                    ON CONFLICT(name) DO UPDATE SET path = excluded.path, role = excluded.role, position = excluded.position
                    """).run([.text(folder.name), .text(path), .optional(folder.role), .int(Int64(position))])
            }
            return removed
        }
    }

    func saveCursor(folder: String, uidValidity: UInt32, highestUID: UInt32, historyComplete: Bool, serverCount: Int) throws {
        try database.prepare("""
            INSERT INTO folder_state (name, path, position, uid_validity, highest_uid, history_complete, server_count)
            VALUES (?, ?, 1000000, ?, ?, ?, ?)
            ON CONFLICT(name) DO UPDATE SET uid_validity = excluded.uid_validity, highest_uid = excluded.highest_uid,
              highest_modseq = CASE WHEN uid_validity IS excluded.uid_validity THEN highest_modseq ELSE NULL END,
              history_complete = excluded.history_complete, server_count = excluded.server_count
            """).run([
                .text(folder), .text(String(decoding: try JSONEncoder().encode([folder]), as: UTF8.self)),
                .int(Int64(uidValidity)), .int(Int64(highestUID)), .int(historyComplete ? 1 : 0), .int(Int64(serverCount)),
            ])
    }

    /// The UIDs on record for a mailbox at one UIDVALIDITY, with their local ids.
    func uids(mailbox: String, uidValidity: UInt32) throws -> [UInt32: MailMessageID] {
        let statement = try database.prepare("SELECT uid, local_id FROM locations WHERE mailbox = ? AND uid_validity = ?")
            .bind([.text(mailbox), .int(Int64(uidValidity))])
        var result: [UInt32: MailMessageID] = [:]
        while try statement.step() {
            if let id = statement.text(1).flatMap(MailMessageID.init) { result[UInt32(statement.int(0))] = id }
        }
        return result
    }

    /// The local ids that are in a mailbox at the provider, as far as this device knows.
    func localIDs(mailbox: String) throws -> Set<MailMessageID> {
        let statement = try database.prepare("SELECT DISTINCT local_id FROM locations WHERE mailbox = ?").bind([.text(mailbox)])
        var result = Set<MailMessageID>()
        while try statement.step() { if let id = statement.text(0).flatMap(MailMessageID.init) { result.insert(id) } }
        return result
    }

    // MARK: Flags

    func setSyncFlags(_ flags: [MailMessageID: MailMessageFlags]) throws {
        // The same table as the reader's seen/flagged (schema 2), with the rest beside it.
        guard !flags.isEmpty else { return }
        try database.transaction {
            let statement = try database.prepare("""
                INSERT OR REPLACE INTO flags (local_id, seen, answered, flagged, draft, keywords) VALUES (?, ?, ?, ?, ?, ?)
                """)
            for (id, flag) in flags.sorted(by: { $0.key < $1.key }) {
                try statement.run([
                    .text(id.rawValue), .int(flag.seen ? 1 : 0), .int(flag.answered ? 1 : 0), .int(flag.flagged ? 1 : 0),
                    .int(flag.draft ? 1 : 0), .text(flag.keywords.sorted().joined(separator: " ")),
                ])
            }
        }
    }

    func syncFlags(of ids: [MailMessageID]) throws -> [MailMessageID: MailMessageFlags] {
        let statement = try database.prepare("SELECT seen, answered, flagged, draft, keywords FROM flags WHERE local_id = ?")
        var result: [MailMessageID: MailMessageFlags] = [:]
        for id in ids {
            _ = try statement.bind([.text(id.rawValue)])
            if try statement.step() {
                let keywords = (statement.text(4) ?? "").split(separator: " ").map(String.init)
                result[id] = MailMessageFlags(seen: statement.int(0) != 0, answered: statement.int(1) != 0,
                                              flagged: statement.int(2) != 0, draft: statement.int(3) != 0, keywords: keywords)
            }
        }
        return result
    }

    // MARK: Counters

    func counter(_ name: String) throws -> Int64 {
        let statement = try database.prepare("SELECT value FROM counters WHERE name = ?").bind([.text(name)])
        return try statement.step() ? Int64(statement.int(0)) : 0
    }

    func add(_ amount: Int64, to name: String) throws {
        try database.prepare("""
            INSERT INTO counters (name, value) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET value = value + excluded.value
            """).run([.text(name), .int(amount)])
    }
}
