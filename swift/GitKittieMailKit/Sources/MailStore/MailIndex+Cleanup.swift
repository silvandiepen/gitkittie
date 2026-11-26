import Foundation
import MailClassifier
import MailCore

// The cleanup dashboard's reads (GKM-021). Read-only: nothing here writes the index.

/// A message as the cleanup analysis sees it: its summary, where its verdict put it, and how
/// many attachment bytes it carries. A message without a verdict reads as Focused and unknown.
struct CleanupRow {
    var summary: MessageSummary
    var listID: String?
    var sender: String?
    var home: MailCategory
    var purpose: MailPurpose
    var bytes: Int64
}

extension MailIndex {
    /// Rows matching `clause` (over `messages m` and `message_classes c`), newest first. Mail
    /// only in Trash or Junk is already cleaned up, and left out (MAIL-102).
    func cleanupRows(where clause: String, _ values: [SQLiteValue]) throws -> [CleanupRow] {
        let statement = try database.prepare("""
            SELECT \(Self.summaryColumns), c.list_id, c.from_address, COALESCE(c.home, 'focused'), COALESCE(c.purpose, 'unknown'),
                   COALESCE((SELECT sum(b.size) FROM message_blobs b WHERE b.local_id = m.local_id), 0)
            FROM messages m LEFT JOIN message_classes c ON c.local_id = m.local_id
            WHERE (\(clause)) AND \(Self.notTrashOrJunk) ORDER BY m.sort_date DESC, m.local_id
            """).bind(values)
        var rows: [CleanupRow] = []
        while try statement.step() {
            guard let summary = Self.summary(statement) else { continue }
            let more = Self.summaryColumnCount
            rows.append(CleanupRow(summary: summary, listID: statement.text(more), sender: statement.text(more + 1),
                                   home: statement.text(more + 2).flatMap(MailCategory.init(rawValue:)) ?? .focused,
                                   purpose: statement.text(more + 3).flatMap(MailPurpose.init(rawValue:)) ?? .unknown,
                                   bytes: Int64(statement.int(more + 4))))
        }
        return rows
    }

    /// The busiest bulk streams (a List-ID, or a sender without one) in Updates, Subscriptions
    /// and Promotions, with at least `minimum` such messages, busiest first.
    func noisyStreams(minimum: Int, limit: Int) throws -> [(account: MailAccountID, list: String?, sender: String?)] {
        let statement = try database.prepare("""
            SELECT c.account_id, c.list_id, CASE WHEN c.list_id IS NULL THEN c.from_address END, count(*) AS volume
            FROM message_classes c JOIN messages m ON m.local_id = c.local_id
            WHERE c.home IN ('updates', 'subscriptions', 'promotions') AND (c.list_id IS NOT NULL OR c.from_address IS NOT NULL)
              AND \(Self.notTrashOrJunk)
            GROUP BY c.account_id, COALESCE('l:' || c.list_id, 's:' || c.from_address)
            HAVING volume >= ? ORDER BY volume DESC, c.account_id, 2, 3 LIMIT ?
            """).bind([.int(Int64(minimum)), .int(Int64(limit))])
        var result: [(MailAccountID, String?, String?)] = []
        while try statement.step() {
            if let account = statement.text(0) { result.append((MailAccountID(account), statement.text(1), statement.text(2))) }
        }
        return result
    }

    /// Messages per account, leaving out mail only in Trash or Junk (MAIL-102).
    func messageCounts() throws -> [MailAccountID: Int] {
        let statement = try database.prepare("SELECT account_id, count(*) FROM messages m WHERE \(Self.notTrashOrJunk) GROUP BY account_id")
        var result: [MailAccountID: Int] = [:]
        while try statement.step() { if let account = statement.text(0) { result[MailAccountID(account)] = statement.int(1) } }
        return result
    }

    /// True when the message is in any space.
    func isInSpace(_ id: MailMessageID) throws -> Bool {
        let statement = try database.prepare("SELECT 1 FROM space_members WHERE local_id = ? LIMIT 1").bind([.text(id.rawValue)])
        return try statement.step()
    }
}
