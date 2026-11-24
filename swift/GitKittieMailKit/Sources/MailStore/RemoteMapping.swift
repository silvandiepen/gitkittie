import Foundation
import MailCore

/// Where each local message sits at the provider: mailbox + UIDVALIDITY + UID → local id.
/// One SQLite file per account in `<Application Support>/Mail/state/<account-id>/sync.sqlite`,
/// beside the sync cursors (GKM-011), because a position at a provider is device state.
///
/// Losing it costs a reconciliation pass (Message-ID and fingerprint candidates from the
/// index), not mail.
final class RemoteMapping {
    static let schemaVersion = 1
    private let database: SQLiteDatabase

    init(url: URL) throws {
        database = try SQLiteDatabase(url: url)
        try database.execute("PRAGMA journal_mode = WAL")
        let version = try database.userVersion
        guard version != Self.schemaVersion else { return }
        guard version == 0 else {
            // Not a cache: never drop it silently. A newer layout needs a newer app.
            throw MailStoreError.unsupportedLayoutVersion(version)
        }
        try database.transaction {
            try database.execute("""
                CREATE TABLE mailboxes (name TEXT PRIMARY KEY, uid_validity INTEGER NOT NULL);
                CREATE TABLE locations (
                  mailbox TEXT NOT NULL, uid_validity INTEGER NOT NULL, uid INTEGER NOT NULL, local_id TEXT NOT NULL,
                  PRIMARY KEY (mailbox, uid_validity, uid)
                );
                CREATE INDEX locations_by_local_id ON locations (local_id);
                """)
            try database.setUserVersion(Self.schemaVersion)
        }
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
