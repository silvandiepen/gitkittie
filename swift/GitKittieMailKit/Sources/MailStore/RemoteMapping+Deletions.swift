import Foundation
import MailCore

// Mail deleted at the provider (GKM-011, decided by Sil; MAIL-075). When the sync sees a
// message leave its last folder at the provider, it is *noticed* here; at the end of a pass
// over every folder, a notice that still has no location (and that a search of the folders
// with mail not downloaded here did not find) is *confirmed*: the message is shown as
// "Deleted at <provider>" with the time it was noticed. A location found again (moved back,
// restored, re-listed) drops the row. Schema 5 of sync.sqlite. Schema 7 (GKM-076, MAIL-105)
// adds when a check last could not tell and how many times in a row it could not, so a notice
// that cannot be decided waits behind the others instead of using up every pass's checks.

/// A message noticed leaving its last folder at the provider, not yet confirmed.
struct NoticedDeletion: Equatable {
    var id: MailMessageID
    var noticedAt: Date
    /// When a check at the provider last could not tell; `nil` when none has failed to.
    var checkedAt: Date? = nil
    /// Checks in a row that could not tell.
    var undecidedChecks: Int = 0
}

extension RemoteMapping {
    func migrateToProviderDeletions() throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS provider_deletions (
              local_id TEXT PRIMARY KEY,
              noticed_at REAL NOT NULL,
              confirmed_at REAL
            );
            """)
    }

    /// Schema 6 → 7 (GKM-076, MAIL-105): when a check last could not tell, and how often in a
    /// row. No notice so far has a check on record.
    func migrateToUndecidedDeletionChecks() throws {
        if try !columnExists("checked_at", in: "provider_deletions") {
            try database.execute("""
                ALTER TABLE provider_deletions ADD COLUMN checked_at REAL;
                ALTER TABLE provider_deletions ADD COLUMN undecided_checks INTEGER NOT NULL DEFAULT 0;
                """)
        }
    }

    /// Notes that `id` has no location at the provider any more, unless it already was.
    func noticeDeletion(of id: MailMessageID, at date: Date) throws {
        try database.prepare("INSERT OR IGNORE INTO provider_deletions (local_id, noticed_at) VALUES (?, ?)")
            .run([.text(id.rawValue), .double(date.timeIntervalSince1970)])
    }

    /// Notices every one of `ids` that has no location left.
    func noticeDeletionsWithoutLocation(_ ids: [MailMessageID], at date: Date) throws {
        for id in ids where try locations(of: id).isEmpty { try noticeDeletion(of: id, at: date) }
    }

    /// The message is at the provider after all, or no longer stored here.
    func clearDeletion(of id: MailMessageID) throws {
        try database.prepare("DELETE FROM provider_deletions WHERE local_id = ?").run([.text(id.rawValue)])
    }

    /// Notices still waiting for a pass to confirm them, in the order to check them (MAIL-105):
    /// first those no check has failed to decide, oldest first, then the rest, the least
    /// recently checked first.
    func unconfirmedDeletions() throws -> [NoticedDeletion] {
        let statement = try database.prepare("""
            SELECT local_id, noticed_at, checked_at, undecided_checks FROM provider_deletions WHERE confirmed_at IS NULL
            ORDER BY checked_at IS NOT NULL, checked_at, noticed_at, local_id
            """)
        var result: [NoticedDeletion] = []
        while try statement.step() {
            if let id = statement.text(0).flatMap(MailMessageID.init) {
                result.append(NoticedDeletion(id: id, noticedAt: Date(timeIntervalSince1970: statement.double(1)),
                                              checkedAt: statement.isNull(2) ? nil : Date(timeIntervalSince1970: statement.double(2)),
                                              undecidedChecks: statement.int(3)))
            }
        }
        return result
    }

    /// A check at the provider could not tell whether the message is gone: it goes behind the
    /// others (MAIL-105). Nothing is confirmed by it.
    func recordUndecidedCheck(of id: MailMessageID, at date: Date) throws {
        try database.prepare("""
            UPDATE provider_deletions SET checked_at = ?, undecided_checks = undecided_checks + 1
            WHERE local_id = ? AND confirmed_at IS NULL
            """).run([.double(date.timeIntervalSince1970), .text(id.rawValue)])
    }

    func confirmDeletion(of id: MailMessageID, at date: Date) throws {
        try database.prepare("UPDATE provider_deletions SET confirmed_at = ? WHERE local_id = ? AND confirmed_at IS NULL")
            .run([.double(date.timeIntervalSince1970), .text(id.rawValue)])
    }

    /// Confirmed deletions with the time each was noticed: when the message was deleted, as
    /// near as this device can tell.
    func confirmedDeletions() throws -> [MailMessageID: Date] {
        let statement = try database.prepare("SELECT local_id, noticed_at FROM provider_deletions WHERE confirmed_at IS NOT NULL")
        var result: [MailMessageID: Date] = [:]
        while try statement.step() {
            if let id = statement.text(0).flatMap(MailMessageID.init) { result[id] = Date(timeIntervalSince1970: statement.double(1)) }
        }
        return result
    }

    /// True when the action journal holds any row for the message: an open change, or a settled
    /// one still within Undo's seven days (MAIL-037).
    func hasActions(for id: MailMessageID) throws -> Bool {
        let statement = try database.prepare("SELECT 1 FROM actions WHERE local_id = ? LIMIT 1").bind([.text(id.rawValue)])
        return try statement.step()
    }

    /// Everything this device keeps about a message whose local copy is gone.
    func removeMessageState(_ id: MailMessageID) throws {
        try database.transaction {
            for table in ["provider_deletions", "flags", "locations"] {
                try database.prepare("DELETE FROM \(table) WHERE local_id = ?").run([.text(id.rawValue)])
            }
        }
    }
}
