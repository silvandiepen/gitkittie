import Foundation
import MailCore

/// Where each local message sits at the provider: mailbox + UIDVALIDITY + UID → local id.
/// One SQLite file per account in `<Application Support>/Mail/state/<account-id>/sync.sqlite`,
/// beside the sync cursors (GKM-011), because a position at a provider is device state.
///
/// Losing it costs a reconciliation pass (Message-ID and fingerprint candidates from the
/// index), not mail.
final class RemoteMapping {
    /// 1: mailboxes and locations (GKM-005). 2: the provider flags this device last saw
    /// (GKM-012). 3: the sync's folder list with a cursor per folder, the rest of the flags
    /// (answered, draft, keywords) and counters (GKM-011; RemoteMapping+Sync.swift).
    static let schemaVersion = 3
    let database: SQLiteDatabase

    init(url: URL) throws {
        database = try SQLiteDatabase(url: url)
        try database.execute("PRAGMA journal_mode = WAL")
        let version = try database.userVersion
        guard version != Self.schemaVersion else { return }
        guard version <= Self.schemaVersion else {
            // Not a cache: never drop it silently. A newer layout needs a newer app.
            throw MailStoreError.unsupportedLayoutVersion(version)
        }
        try database.transaction {
            if version == 0 {
                try database.execute("""
                    CREATE TABLE mailboxes (name TEXT PRIMARY KEY, uid_validity INTEGER NOT NULL);
                    CREATE TABLE locations (
                      mailbox TEXT NOT NULL, uid_validity INTEGER NOT NULL, uid INTEGER NOT NULL, local_id TEXT NOT NULL,
                      PRIMARY KEY (mailbox, uid_validity, uid)
                    );
                    CREATE INDEX locations_by_local_id ON locations (local_id);
                    """)
            }
            if version < 2 {
                // 1 → 2: the provider flags this device last saw (GKM-012).
                try database.execute("CREATE TABLE flags (local_id TEXT PRIMARY KEY, seen INTEGER NOT NULL, flagged INTEGER NOT NULL)")
            }
            if version < 3 {
                // 2 → 3: the sync's folders, cursors and counters, and the remaining flags (GKM-011).
                try migrateToSyncState()
            }
            try database.setUserVersion(Self.schemaVersion)
        }
    }

    func flags(of id: MailMessageID) throws -> MessageFlags {
        let statement = try database.prepare("SELECT seen, flagged FROM flags WHERE local_id = ?").bind([.text(id.rawValue)])
        return try statement.step() ? MessageFlags(seen: statement.int(0) != 0, flagged: statement.int(1) != 0) : MessageFlags()
    }

    func setFlags(_ flags: MessageFlags, for id: MailMessageID) throws {
        // An upsert, so the flags only the sync knows (answered, draft, keywords; schema 3) stay.
        try database.prepare("""
            INSERT INTO flags (local_id, seen, flagged) VALUES (?, ?, ?)
            ON CONFLICT(local_id) DO UPDATE SET seen = excluded.seen, flagged = excluded.flagged
            """)
            .run([.text(id.rawValue), .int(flags.seen ? 1 : 0), .int(flags.flagged ? 1 : 0)])
    }

    func allFlags() throws -> [MailMessageID: MessageFlags] {
        let statement = try database.prepare("SELECT local_id, seen, flagged FROM flags")
        var result: [MailMessageID: MessageFlags] = [:]
        while try statement.step() {
            if let id = statement.text(0).flatMap(MailMessageID.init) {
                result[id] = MessageFlags(seen: statement.int(1) != 0, flagged: statement.int(2) != 0)
            }
        }
        return result
    }

    /// Every (message, mailbox) pair on record.
    func allMemberships() throws -> [(MailMessageID, String)] {
        let statement = try database.prepare("SELECT DISTINCT local_id, mailbox FROM locations ORDER BY local_id, mailbox")
        var result: [(MailMessageID, String)] = []
        while try statement.step() {
            if let id = statement.text(0).flatMap(MailMessageID.init), let mailbox = statement.text(1) { result.append((id, mailbox)) }
        }
        return result
    }

    /// The messages with a location in `mailbox`.
    func localIDs(inMailbox mailbox: String) throws -> [MailMessageID] {
        let statement = try database.prepare("SELECT DISTINCT local_id FROM locations WHERE mailbox = ? ORDER BY local_id").bind([.text(mailbox)])
        var ids: [MailMessageID] = []
        while try statement.step() { if let id = statement.text(0).flatMap(MailMessageID.init) { ids.append(id) } }
        return ids
    }

    func localID(at location: RemoteLocation) throws -> MailMessageID? {
        let statement = try database.prepare("SELECT local_id FROM locations WHERE mailbox = ? AND uid_validity = ? AND uid = ?")
            .bind(Self.key(location))
        return try statement.step() ? statement.text(0).flatMap(MailMessageID.init) : nil
    }

    func record(_ location: RemoteLocation, for id: MailMessageID) throws {
        try database.transaction {
            try database.prepare("INSERT OR IGNORE INTO mailboxes (name, uid_validity) VALUES (?, ?)")
                .run([.text(location.mailbox), .int(Int64(location.uidValidity))])
            try database.prepare("INSERT OR REPLACE INTO locations (mailbox, uid_validity, uid, local_id) VALUES (?, ?, ?, ?)")
                .run(Self.key(location) + [.text(id.rawValue)])
        }
    }

    func forget(_ location: RemoteLocation) throws {
        try database.prepare("DELETE FROM locations WHERE mailbox = ? AND uid_validity = ? AND uid = ?").run(Self.key(location))
    }

    func locations(of id: MailMessageID) throws -> [RemoteLocation] {
        let statement = try database.prepare("SELECT mailbox, uid_validity, uid FROM locations WHERE local_id = ? ORDER BY mailbox, uid")
            .bind([.text(id.rawValue)])
        var result: [RemoteLocation] = []
        while try statement.step() {
            result.append(RemoteLocation(mailbox: statement.text(0) ?? "", uidValidity: UInt32(statement.int(1)), uid: UInt32(statement.int(2))))
        }
        return result
    }

    func mailboxes() throws -> [String] {
        let statement = try database.prepare("SELECT name FROM mailboxes ORDER BY name")
        var names: [String] = []
        while try statement.step() { if let name = statement.text(0) { names.append(name) } }
        return names
    }

    /// The server reported `uidValidity` for `mailbox`. When it differs from the one on record,
    /// every UID in that mailbox is void: the old locations are dropped and the ids that are left
    /// with no location at all are returned, for the sync to reconcile by Message-ID/fingerprint.
    func setUIDValidity(_ uidValidity: UInt32, mailbox: String) throws -> [MailMessageID] {
        try database.transaction {
            let current = try database.prepare("SELECT uid_validity FROM mailboxes WHERE name = ?").bind([.text(mailbox)])
            let known = try current.step() ? UInt32(current.int(0)) : nil
            guard known != uidValidity else { return [] }
            var affected: [MailMessageID] = []
            let stale = try database.prepare("SELECT DISTINCT local_id FROM locations WHERE mailbox = ? AND uid_validity != ? ORDER BY local_id")
                .bind([.text(mailbox), .int(Int64(uidValidity))])
            while try stale.step() { if let id = stale.text(0).flatMap(MailMessageID.init) { affected.append(id) } }
            try database.prepare("DELETE FROM locations WHERE mailbox = ? AND uid_validity != ?").run([.text(mailbox), .int(Int64(uidValidity))])
            try database.prepare("INSERT OR REPLACE INTO mailboxes (name, uid_validity) VALUES (?, ?)").run([.text(mailbox), .int(Int64(uidValidity))])
            return try affected.filter { try locations(of: $0).isEmpty }
        }
    }

    private static func key(_ location: RemoteLocation) -> [SQLiteValue] {
        [.text(location.mailbox), .int(Int64(location.uidValidity)), .int(Int64(location.uid))]
    }
}
