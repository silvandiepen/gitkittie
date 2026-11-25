import Foundation
import MailCore

// Mail in Trash or Junk leaves every other view (GKM-075, MAIL-102).
//
// The index keeps each account's Trash and Junk folders (`trash_and_junk_mailboxes`, device
// state copied from the sync's folder roles by the store) and marks each message whose folders
// are all among them (`messages.trash_or_junk`). Triggers keep the mark right whenever a
// message's folders, the message row or an account's Trash and Junk change, so every writer of
// `message_mailboxes` (sync, actions and their overlay, Undo, rebuild, recovery) is covered
// without having to remember it. Views then filter on one column of the row they already read:
// counts and paging stay exact, and no list query gains a join.
//
// A message in no folder at all (imported into "On My Mac", or deleted at the provider,
// MAIL-075) is not marked: it never was in Trash or Junk here.

extension MailIndex {
    /// The filter every view adds (over `messages m`): not only in Trash or Junk.
    static let notTrashOrJunk = "m.trash_or_junk = 0"

    /// 1 when the message `messages.local_id` is in at least one folder and every folder it is
    /// in is its account's Trash or Junk. Each lookup is on a primary key.
    static let trashOrJunkExpression = """
        (EXISTS (SELECT 1 FROM message_mailboxes b JOIN trash_and_junk_mailboxes t
                   ON t.account_id = b.account_id AND t.mailbox = b.mailbox
                 WHERE b.local_id = messages.local_id)
         AND NOT EXISTS (SELECT 1 FROM message_mailboxes b WHERE b.local_id = messages.local_id
                   AND NOT EXISTS (SELECT 1 FROM trash_and_junk_mailboxes t
                                   WHERE t.account_id = b.account_id AND t.mailbox = b.mailbox)))
        """

    /// Schema 8: the column, then ``trashAndJunkTablesSQL``.
    static let trashAndJunkSQL = """
        ALTER TABLE messages ADD COLUMN trash_or_junk INTEGER NOT NULL DEFAULT 0;
        """ + trashAndJunkTablesSQL

    /// Schema 7 → 8 in place. The column only when missing: an index taken back to an older
    /// version (tests do that) may already have it.
    func addTrashAndJunk() throws {
        let column = try database.prepare("SELECT 1 FROM pragma_table_info('messages') WHERE name = 'trash_or_junk'")
        if try !column.step() {
            try database.execute("ALTER TABLE messages ADD COLUMN trash_or_junk INTEGER NOT NULL DEFAULT 0")
        }
        try database.execute(Self.trashAndJunkTablesSQL)
    }

    /// The folders and the triggers that keep the column right.
    static let trashAndJunkTablesSQL = """
        CREATE TABLE IF NOT EXISTS trash_and_junk_mailboxes (
          account_id TEXT NOT NULL, mailbox TEXT NOT NULL, role TEXT NOT NULL, PRIMARY KEY (account_id, mailbox)
        );
        CREATE TRIGGER IF NOT EXISTS trash_or_junk_after_message AFTER INSERT ON messages BEGIN
          UPDATE messages SET trash_or_junk = \(trashOrJunkExpression) WHERE rowid = NEW.rowid;
        END;
        CREATE TRIGGER IF NOT EXISTS trash_or_junk_after_location_insert AFTER INSERT ON message_mailboxes BEGIN
          UPDATE messages SET trash_or_junk = \(trashOrJunkExpression) WHERE local_id = NEW.local_id;
        END;
        CREATE TRIGGER IF NOT EXISTS trash_or_junk_after_location_delete AFTER DELETE ON message_mailboxes BEGIN
          UPDATE messages SET trash_or_junk = \(trashOrJunkExpression) WHERE local_id = OLD.local_id;
        END;
        CREATE TRIGGER IF NOT EXISTS trash_or_junk_after_location_update AFTER UPDATE ON message_mailboxes BEGIN
          UPDATE messages SET trash_or_junk = \(trashOrJunkExpression) WHERE local_id IN (OLD.local_id, NEW.local_id);
        END;
        CREATE TRIGGER IF NOT EXISTS trash_or_junk_after_folder_insert AFTER INSERT ON trash_and_junk_mailboxes BEGIN
          UPDATE messages SET trash_or_junk = \(trashOrJunkExpression) WHERE local_id IN
            (SELECT local_id FROM message_mailboxes WHERE account_id = NEW.account_id AND mailbox = NEW.mailbox);
        END;
        CREATE TRIGGER IF NOT EXISTS trash_or_junk_after_folder_delete AFTER DELETE ON trash_and_junk_mailboxes BEGIN
          UPDATE messages SET trash_or_junk = \(trashOrJunkExpression) WHERE local_id IN
            (SELECT local_id FROM message_mailboxes WHERE account_id = OLD.account_id AND mailbox = OLD.mailbox);
        END;
        """

    /// The account's Trash and Junk folders, by name, with their role (`trash`, `junk`).
    func trashAndJunkMailboxes(account: MailAccountID) throws -> [String: String] {
        let statement = try database.prepare("SELECT mailbox, role FROM trash_and_junk_mailboxes WHERE account_id = ?")
            .bind([.text(account.rawValue)])
        var result: [String: String] = [:]
        while try statement.step() {
            if let mailbox = statement.text(0), let role = statement.text(1) { result[mailbox] = role }
        }
        return result
    }

    /// Replaces the account's Trash and Junk folders. Only what changed is written, so the
    /// triggers re-mark only the mail in folders that gained or lost the role; unchanged, it
    /// writes nothing (it runs on every open and every folder list).
    func setTrashAndJunkMailboxes(_ wanted: [String: String], account: MailAccountID) throws {
        let current = try trashAndJunkMailboxes(account: account)
        guard current != wanted else { return }
        try database.transaction {
            let delete = try database.prepare("DELETE FROM trash_and_junk_mailboxes WHERE account_id = ? AND mailbox = ?")
            for (mailbox, role) in current where wanted[mailbox] != role {
                try delete.run([.text(account.rawValue), .text(mailbox)])
            }
            let insert = try database.prepare("INSERT INTO trash_and_junk_mailboxes (account_id, mailbox, role) VALUES (?, ?, ?)")
            for (mailbox, role) in wanted.sorted(by: { $0.key < $1.key }) where current[mailbox] != role {
                try insert.run([.text(account.rawValue), .text(mailbox), .text(role)])
            }
        }
    }

    /// True when the message is only in Trash or Junk.
    func isTrashOrJunk(_ id: MailMessageID) throws -> Bool {
        let statement = try database.prepare("SELECT trash_or_junk FROM messages WHERE local_id = ?").bind([.text(id.rawValue)])
        return try statement.step() && statement.int(0) != 0
    }
}
