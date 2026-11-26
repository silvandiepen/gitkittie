import Foundation
import MailClassifier
import MailCore

// The sender and list directory (GKM-019), read from the index: who sends you what, how much,
// in which views, and since when. Derived like the rest of the index; nothing here is user data.

/// One sender or mailing list in one account, as the Senders view lists it.
public struct SenderSummary: Sendable, Identifiable, Hashable {
    public var id: String { Self.key(account: account, scope: scope) }
    public var account: MailAccountID
    /// A list (List-ID and the organisation sending it) or a sender address.
    public var scope: SenderScope
    /// The newest message's display name and address.
    public var name: String?
    public var address: String?
    /// The sender's organisation domain (Public Suffix List). Grouping by it is informational:
    /// one domain is no proof that two senders belong to the same company.
    public var organisation: String?
    public var messages: Int
    public var unread: Int
    /// Messages dated in the last 30 days.
    public var recent: Int
    public var firstSeen: Date
    public var lastSeen: Date
    /// Messages per category view they live in (muted mail counts under its category).
    public var categories: [MailCategory: Int]
    /// Muted or silently archived by one of your rules.
    public var silenced: Int
    /// Opened in this app on this Mac; mail read in other apps or on other devices is not
    /// counted, so this is incomplete by design.
    public var opens: Int
    public var lastOpened: Date?

    /// The view most of its mail lives in.
    public var mainCategory: MailCategory {
        categories.max { ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue) }?.key ?? .focused
    }

    public static func key(account: MailAccountID, scope: SenderScope) -> String {
        switch scope {
        case .list(let id, let organisation): "\(account.rawValue)|list|\(id)|\(organisation ?? "")"
        case .sender(let address): "\(account.rawValue)|sender|\(address)"
        }
    }
}

/// A message as a sender rule sees it, for previews and keep-latest.
struct SenderScopeMember {
    var id: MailMessageID
    var fingerprint: String
    var date: Date
}

extension MailIndex {
    /// Every sender and list, newest first. Mail on a list belongs to the list (grouped with the
    /// organisation that sent it, so a copied List-ID shows as its own entry); other mail to its
    /// From address. Unclassified mail is not listed until it is classified.
    func senderDirectory(account: MailAccountID?, now: Date) throws -> [SenderSummary] {
        var sql = """
            SELECT c.account_id, c.list_id, c.from_domain, c.from_address, c.home, c.disposition,
                   count(*), sum(1 - m.seen), sum(m.sort_date >= ?), min(m.sort_date), max(m.sort_date),
                   (SELECT m2.from_name FROM messages m2 JOIN message_classes c2 ON c2.local_id = m2.local_id
                    WHERE c2.account_id = c.account_id AND c2.list_id IS c.list_id AND m2.trash_or_junk = 0
                      AND (c.list_id IS NOT NULL OR c2.from_address IS c.from_address)
                    ORDER BY m2.sort_date DESC LIMIT 1)
            FROM message_classes c JOIN messages m ON m.local_id = c.local_id
            WHERE (c.list_id IS NOT NULL OR c.from_address IS NOT NULL) AND \(Self.notTrashOrJunk)
            """
        var values: [SQLiteValue] = [.double(now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970)]
        if let account { sql += " AND c.account_id = ?"; values.append(.text(account.rawValue)) }
        sql += """
             GROUP BY c.account_id, c.list_id, CASE WHEN c.list_id IS NULL THEN c.from_address ELSE c.from_domain END, c.home, c.disposition
            """
        let statement = try database.prepare(sql).bind(values)
        var found: [String: SenderSummary] = [:]
        while try statement.step() {
            guard let accountRaw = statement.text(0) else { continue }
            let account = MailAccountID(accountRaw)
            let list = statement.text(1), domain = statement.text(2), address = statement.text(3)
            let scope: SenderScope
            if let list { scope = .list(id: list, organisation: domain) } else if let address { scope = .sender(address) } else { continue }
            let home = statement.text(4).flatMap(MailCategory.init(rawValue:)) ?? .focused
            let disposition = statement.text(5).flatMap(SenderDisposition.init(rawValue:))
            let count = statement.int(6), unread = statement.int(7), recent = statement.int(8)
            let first = Date(timeIntervalSince1970: statement.double(9)), last = Date(timeIntervalSince1970: statement.double(10))
            let key = SenderSummary.key(account: account, scope: scope)
            var entry = found[key] ?? SenderSummary(account: account, scope: scope, name: nil, address: address, organisation: domain,
                                                    messages: 0, unread: 0, recent: 0, firstSeen: first, lastSeen: last,
                                                    categories: [:], silenced: 0, opens: 0, lastOpened: nil)
            entry.messages += count
            entry.unread += unread
            entry.recent += recent
            if first < entry.firstSeen { entry.firstSeen = first }
            if last >= entry.lastSeen { entry.lastSeen = last; entry.address = address ?? entry.address }
            entry.name = entry.name ?? statement.text(11)
            entry.categories[home, default: 0] += count
            if disposition == .muted || disposition == .archived { entry.silenced += count }
            found[key] = entry
        }
        return found.values.sorted { ($0.lastSeen, $0.id) > ($1.lastSeen, $1.id) }
    }

    /// Classified messages a scope covers, newest first (ignoring rules and exclusions). Rules
    /// see every one; the sender's view leaves out mail only in Trash or Junk (MAIL-102).
    func members(of scope: SenderScope, account: MailAccountID, includesTrashAndJunk: Bool = true) throws -> [SenderScopeMember] {
        var sql = """
            SELECT m.local_id, m.fingerprint, m.sort_date FROM message_classes c JOIN messages m ON m.local_id = c.local_id
            WHERE c.account_id = ?
            """
        if !includesTrashAndJunk { sql += " AND \(Self.notTrashOrJunk)" }
        var values: [SQLiteValue] = [.text(account.rawValue)]
        switch scope {
        case .list(let id, let organisation):
            sql += " AND c.list_id = ?"
            values.append(.text(id))
            if let organisation { sql += " AND c.from_domain = ?"; values.append(.text(organisation)) }
        case .sender(let address):
            sql += " AND c.from_address = ?"
            values.append(.text(address))
        }
        let statement = try database.prepare(sql + " ORDER BY m.sort_date DESC, m.local_id DESC").bind(values)
        var result: [SenderScopeMember] = []
        while try statement.step() {
            guard let raw = statement.text(0), let id = MailMessageID(raw), let fingerprint = statement.text(1) else { continue }
            result.append(SenderScopeMember(id: id, fingerprint: fingerprint, date: Date(timeIntervalSince1970: statement.double(2))))
        }
        return result
    }

    /// The date a message sorts by, and its content fingerprint.
    func dateAndFingerprint(of id: MailMessageID) throws -> (date: Date, fingerprint: String)? {
        let statement = try database.prepare("SELECT sort_date, fingerprint FROM messages WHERE local_id = ?").bind([.text(id.rawValue)])
        guard try statement.step(), let fingerprint = statement.text(1) else { return nil }
        return (Date(timeIntervalSince1970: statement.double(0)), fingerprint)
    }

    /// Messages a rule decided, by rule id.
    func messages(decidedBy rule: String) throws -> [(id: MailMessageID, account: MailAccountID)] {
        let statement = try database.prepare("SELECT local_id, account_id FROM message_classes WHERE sender_rule = ? ORDER BY local_id")
            .bind([.text(rule)])
        var result: [(MailMessageID, MailAccountID)] = []
        while try statement.step() {
            if let raw = statement.text(0), let id = MailMessageID(raw), let account = statement.text(1) { result.append((id, MailAccountID(account))) }
        }
        return result
    }
}

extension MailIndex {
    /// One message as the list shows it.
    func summary(of id: MailMessageID) throws -> MessageSummary? {
        let statement = try database.prepare("SELECT \(Self.summaryColumns) FROM messages m WHERE m.local_id = ?").bind([.text(id.rawValue)])
        return try statement.step() ? Self.summary(statement) : nil
    }
}
