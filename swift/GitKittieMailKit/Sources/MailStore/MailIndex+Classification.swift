import Foundation
import MailClassifier
import MailCore

// The classifier's verdicts in the index (GKM-017, MAIL-038). Verdicts are derived like the rest
// of the index: from the message, the rule set and what the mailbox history says (who you have
// written to, which domains passed trusted authentication). Deleting the index loses nothing; the
// store classifies again. Corrections and rules are user data and live elsewhere
// (`ClassificationMetadata`), so a rebuild or a rule-set upgrade can never lose them.

/// A message's stored verdict.
public struct StoredVerdict: Sendable, Equatable {
    public var id: MailMessageID
    public var account: MailAccountID
    public var classification: Classification
    public var home: MailCategory
    /// A correction or a rule of yours decided it.
    public var isCorrected: Bool
    public var fromAddress: String?
    /// The List-ID, without angle brackets, lowercased.
    public var listID: String?
    /// The sender rule that won for this message (GKM-019), if any matched.
    public var senderRule: String?
    /// Where that rule put it, besides its category: in Focused, silently archived or muted.
    public var disposition: SenderDisposition?

    public init(id: MailMessageID, account: MailAccountID, classification: Classification, home: MailCategory, isCorrected: Bool,
                fromAddress: String?, listID: String?, senderRule: String? = nil, disposition: SenderDisposition? = nil) {
        self.id = id
        self.account = account
        self.classification = classification
        self.home = home
        self.isCorrected = isCorrected
        self.fromAddress = fromAddress
        self.listID = listID
        self.senderRule = senderRule
        self.disposition = disposition
    }

    /// Muted and silently archived mail never asks for attention.
    public var isSilenced: Bool { disposition == .muted || disposition == .archived }
}

/// Messages and unread messages in a category view.
public struct CategoryCount: Sendable, Equatable {
    public var total = 0
    public var unread = 0
    public init(total: Int = 0, unread: Int = 0) {
        self.total = total
        self.unread = unread
    }
}

/// A message classified as it arrived (not on a rebuild or a reclassification): what
/// notifications look at.
public struct MailArrival: Sendable, Equatable {
    public var sequence: Int64
    public var id: MailMessageID
    public var account: MailAccountID
    public var home: MailCategory
    public var listID: String?
    public var fromName: String?
    public var fromAddress: String?
    public var subject: String?
    public var received: Date
    public var isUnread: Bool
    /// The sender rule that won, and where it put the message (GKM-019).
    public var senderRule: String?
    public var disposition: SenderDisposition?
    /// The spaces it is in when it is considered (GKM-037): what per-space notification
    /// settings look at. A space's rules run over new mail before notifications do.
    public var spaces: Set<MailSpaceID> = []
    /// Muted and silently archived mail never notifies.
    public var isSilenced: Bool { disposition == .muted || disposition == .archived }
}

extension MailCategory {
    /// The name in `category:` searches; singular and plural both work.
    public init?(searchName: String) {
        let name = searchName.lowercased()
        if let exact = MailCategory(rawValue: name) { self = exact; return }
        switch name {
        case "focus", "inbox": self = .focused
        case "transaction", "receipts": self = .transactions
        case "update", "notification", "notifications": self = .updates
        case "subscription", "newsletter", "newsletters": self = .subscriptions
        case "promotion", "promo", "promos": self = .promotions
        case "spam", "junk", "phishing": self = .quarantine
        default: return nil
        }
    }
}

extension MailIndex {
    static let classificationSQL = """
        CREATE TABLE IF NOT EXISTS message_classes (
          local_id TEXT PRIMARY KEY,
          account_id TEXT NOT NULL,
          home TEXT NOT NULL,
          purpose TEXT NOT NULL,
          risk TEXT NOT NULL,
          urgency TEXT NOT NULL,
          verdict TEXT NOT NULL,
          rule_version TEXT NOT NULL,
          corrected INTEGER NOT NULL DEFAULT 0,
          from_address TEXT,
          from_domain TEXT,
          list_id TEXT,
          arrival INTEGER
        );
        CREATE INDEX IF NOT EXISTS message_classes_by_home ON message_classes (home, purpose);
        CREATE INDEX IF NOT EXISTS message_classes_by_sender ON message_classes (account_id, from_address);
        CREATE INDEX IF NOT EXISTS message_classes_by_list ON message_classes (account_id, list_id);
        CREATE INDEX IF NOT EXISTS message_classes_by_domain ON message_classes (from_domain);
        CREATE INDEX IF NOT EXISTS message_classes_by_arrival ON message_classes (arrival) WHERE arrival IS NOT NULL;
        CREATE INDEX IF NOT EXISTS message_classes_by_version ON message_classes (rule_version);
        CREATE TABLE IF NOT EXISTS correspondents (address TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS authenticated_domains (
          domain TEXT PRIMARY KEY, first_seen REAL NOT NULL, last_seen REAL NOT NULL, messages INTEGER NOT NULL
        );
        """

    /// Schema 5 (GKM-019): the sender rule that won and where it put the message. A muted or
    /// silently archived message leaves Focused; a muted one leaves the category views too.
    static let senderRuleColumnsSQL = """
        ALTER TABLE message_classes ADD COLUMN sender_rule TEXT;
        ALTER TABLE message_classes ADD COLUMN disposition TEXT;
        CREATE INDEX IF NOT EXISTS message_classes_by_rule ON message_classes (sender_rule) WHERE sender_rule IS NOT NULL;
        """

    /// The category filter over `messages m`. A message without a verdict is in Focused.
    static func categoryClause(_ category: MailCategory) -> (String, [SQLiteValue]) {
        switch category {
        case .focused:
            return ("""
                NOT EXISTS (SELECT 1 FROM message_classes c WHERE c.local_id = m.local_id
                  AND (c.home != 'focused' OR c.disposition IN ('muted', 'archived')))
                """, [])
        case .quarantine:
            return ("EXISTS (SELECT 1 FROM message_classes c WHERE c.local_id = m.local_id AND c.home = 'quarantine')", [])
        case .transactions, .updates, .subscriptions, .promotions:
            return ("""
                EXISTS (SELECT 1 FROM message_classes c WHERE c.local_id = m.local_id
                  AND (c.home = ? OR (c.purpose = ? AND c.home != 'quarantine')) AND c.disposition IS NOT 'muted')
                """, [.text(category.rawValue), .text(category.purpose?.rawValue ?? "")])
        }
    }

    // MARK: Writing

    /// Stores a verdict. The arrival number is given once, when the message is classified as
    /// it arrives, and kept through every later reclassification.
    func saveVerdict(_ verdict: StoredVerdict, fromDomain: String?, arrival: Bool) throws {
        let json = String(decoding: try JSONCoding.encoder.encode(verdict.classification), as: UTF8.self)
        let c = verdict.classification
        var next: Int64?
        if arrival {
            let statement = try database.prepare(Self.latestArrivalSQL)
            next = try statement.step() ? Int64(statement.int(0)) + 1 : 1
        }
        try database.prepare("""
            INSERT INTO message_classes (local_id, account_id, home, purpose, risk, urgency, verdict, rule_version, corrected,
                                         from_address, from_domain, list_id, arrival, sender_rule, disposition)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(local_id) DO UPDATE SET
              account_id = excluded.account_id, home = excluded.home, purpose = excluded.purpose, risk = excluded.risk,
              urgency = excluded.urgency, verdict = excluded.verdict, rule_version = excluded.rule_version,
              corrected = excluded.corrected, from_address = excluded.from_address, from_domain = excluded.from_domain,
              list_id = excluded.list_id, arrival = COALESCE(message_classes.arrival, excluded.arrival),
              sender_rule = excluded.sender_rule, disposition = excluded.disposition
            """).run([
                .text(verdict.id.rawValue), .text(verdict.account.rawValue), .text(verdict.home.rawValue),
                .text(c.purpose.rawValue), .text(c.risk.rawValue), .text(c.urgency.rawValue), .text(json),
                .text(c.ruleSetVersion), .int(verdict.isCorrected ? 1 : 0), .optional(verdict.fromAddress),
                .optional(fromDomain), .optional(verdict.listID), next.map { .int($0) } ?? .null,
                .optional(verdict.senderRule), .optional(verdict.disposition?.rawValue),
            ])
    }

    /// Adds addresses you have written to; returns the ones that are new.
    func addCorrespondents(_ addresses: Set<String>) throws -> Set<String> {
        var added = Set<String>()
        let insert = try database.prepare("INSERT OR IGNORE INTO correspondents (address) VALUES (?)")
        for address in addresses.sorted() {
            try insert.run([.text(address)])
            if database.changes > 0 { added.insert(address) }
        }
        return added
    }

    func correspondents() throws -> Set<String> {
        let statement = try database.prepare("SELECT address FROM correspondents")
        var result = Set<String>()
        while try statement.step() { if let address = statement.text(0) { result.insert(address) } }
        return result
    }

    /// Records that a message from `domain` passed authentication at a trusted server.
    func recordAuthenticatedDomain(_ domain: String, at date: Date) throws {
        try database.prepare("""
            INSERT INTO authenticated_domains (domain, first_seen, last_seen, messages) VALUES (?, ?, ?, 1)
            ON CONFLICT(domain) DO UPDATE SET first_seen = min(first_seen, excluded.first_seen),
              last_seen = max(last_seen, excluded.last_seen), messages = messages + 1
            """).run([.text(domain), .double(date.timeIntervalSince1970), .double(date.timeIntervalSince1970)])
    }

    func authenticatedDomains() throws -> [(domain: String, firstSeen: Date, lastSeen: Date, messages: Int)] {
        let statement = try database.prepare("SELECT domain, first_seen, last_seen, messages FROM authenticated_domains ORDER BY domain")
        var result: [(String, Date, Date, Int)] = []
        while try statement.step() {
            if let domain = statement.text(0) {
                result.append((domain, Date(timeIntervalSince1970: statement.double(1)), Date(timeIntervalSince1970: statement.double(2)),
                               statement.int(3)))
            }
        }
        return result
    }

    // MARK: Reading

    func verdict(of id: MailMessageID) throws -> StoredVerdict? {
        let statement = try database.prepare("""
            SELECT local_id, account_id, verdict, home, corrected, from_address, list_id, sender_rule, disposition
            FROM message_classes WHERE local_id = ?
            """).bind([.text(id.rawValue)])
        guard try statement.step(), let json = statement.text(2), let home = statement.text(3).flatMap(MailCategory.init(rawValue:)),
              let account = statement.text(1),
              let classification = try? JSONCoding.decoder.decode(Classification.self, from: Data(json.utf8)) else { return nil }
        return StoredVerdict(id: id, account: MailAccountID(account), classification: classification, home: home,
                             isCorrected: statement.int(4) != 0, fromAddress: statement.text(5), listID: statement.text(6),
                             senderRule: statement.text(7), disposition: statement.text(8).flatMap(SenderDisposition.init(rawValue:)))
    }

    /// Messages with no verdict, or one from another rule set, oldest local id first.
    func unclassified(ruleSetVersion: String, limit: Int) throws -> [(id: MailMessageID, account: MailAccountID)] {
        let statement = try database.prepare("""
            SELECT m.local_id, m.account_id FROM messages m LEFT JOIN message_classes c ON c.local_id = m.local_id
            WHERE c.local_id IS NULL OR c.rule_version != ? ORDER BY m.local_id LIMIT ?
            """).bind([.text(ruleSetVersion), .int(Int64(limit))])
        return try Self.idsAndAccounts(statement)
    }

    func unclassifiedCount(ruleSetVersion: String) throws -> Int {
        let statement = try database.prepare("""
            SELECT count(*) FROM messages m LEFT JOIN message_classes c ON c.local_id = m.local_id
            WHERE c.local_id IS NULL OR c.rule_version != ?
            """).bind([.text(ruleSetVersion)])
        return try statement.step() ? statement.int(0) : 0
    }

    /// Classified messages from these senders (any account when `account` is nil).
    func messages(fromAddresses addresses: Set<String>, account: MailAccountID?) throws -> [(id: MailMessageID, account: MailAccountID)] {
        guard !addresses.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: addresses.count).joined(separator: ",")
        var values = addresses.sorted().map(SQLiteValue.text)
        var sql = "SELECT local_id, account_id FROM message_classes WHERE from_address IN (\(placeholders))"
        if let account { sql += " AND account_id = ?"; values.append(.text(account.rawValue)) }
        return try Self.idsAndAccounts(database.prepare(sql + " ORDER BY local_id").bind(values))
    }

    func messages(inList listID: String, account: MailAccountID) throws -> [(id: MailMessageID, account: MailAccountID)] {
        try Self.idsAndAccounts(database.prepare("SELECT local_id, account_id FROM message_classes WHERE list_id = ? AND account_id = ? ORDER BY local_id")
            .bind([.text(listID), .text(account.rawValue)]))
    }

    func messages(fromDomains domains: Set<String>) throws -> [(id: MailMessageID, account: MailAccountID)] {
        guard !domains.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: domains.count).joined(separator: ",")
        return try Self.idsAndAccounts(database.prepare("SELECT local_id, account_id FROM message_classes WHERE from_domain IN (\(placeholders)) ORDER BY local_id")
            .bind(domains.sorted().map(SQLiteValue.text)))
    }

    /// Every sender organisation seen, for finding lookalikes of a newly trusted one.
    func senderDomains() throws -> Set<String> {
        let statement = try database.prepare("SELECT DISTINCT from_domain FROM message_classes WHERE from_domain IS NOT NULL")
        var result = Set<String>()
        while try statement.step() { if let domain = statement.text(0) { result.insert(domain) } }
        return result
    }

    /// Messages and unread messages per category view, for one account or all.
    func categoryCounts(account: MailAccountID?) throws -> [MailCategory: CategoryCount] {
        var sql = """
            SELECT COALESCE(c.home, 'focused'), c.purpose, c.disposition, count(*), sum(1 - m.seen) FROM messages m
            LEFT JOIN message_classes c ON c.local_id = m.local_id
            """
        var values: [SQLiteValue] = []
        if let account { sql += " WHERE m.account_id = ?"; values.append(.text(account.rawValue)) }
        let statement = try database.prepare(sql + " GROUP BY 1, 2, 3").bind(values)
        var counts: [MailCategory: CategoryCount] = [:]
        while try statement.step() {
            guard let home = statement.text(0).flatMap(MailCategory.init(rawValue:)) else { continue }
            let purpose = statement.text(1).flatMap(MailPurpose.init(rawValue:))
            let disposition = statement.text(2).flatMap(SenderDisposition.init(rawValue:))
            let total = statement.int(3), unread = statement.int(4)
            for category in MailCategory.allCases where Self.isListed(home: home, purpose: purpose, disposition: disposition, in: category) {
                counts[category, default: CategoryCount()].total += total
                counts[category, default: CategoryCount()].unread += unread
            }
        }
        return counts
    }

    /// The same membership as `categoryClause`, for counting.
    static func isListed(home: MailCategory, purpose: MailPurpose?, disposition: SenderDisposition?, in category: MailCategory) -> Bool {
        switch category {
        case .focused: return home == .focused && disposition != .muted && disposition != .archived
        case .quarantine: return home == .quarantine
        default:
            guard disposition != .muted else { return false }
            return home == category || (category.purpose != nil && category.purpose == purpose && home != .quarantine)
        }
    }

    /// The newest arrival number, from the partial arrival index. Without `arrival IS NOT NULL`
    /// SQLite cannot use that index and reads every verdict: once for every arriving message,
    /// which made a large first sync slower with every message stored (GKM-040).
    static let latestArrivalSQL = "SELECT COALESCE(MAX(arrival), 0) FROM message_classes WHERE arrival IS NOT NULL"

    func latestArrival() throws -> Int64 {
        let statement = try database.prepare(Self.latestArrivalSQL)
        return try statement.step() ? Int64(statement.int(0)) : 0
    }

    /// Arrivals after a number, with the spaces each is in (GKM-037), looked up through
    /// `space_members_by_message`, never a scan of every membership.
    static let arrivalsSQL = """
        SELECT c.arrival, c.local_id, c.account_id, c.home, c.list_id, m.from_name, m.from_address, m.subject, m.sort_date, m.seen,
               c.sender_rule, c.disposition,
               (SELECT group_concat(s.space_id) FROM space_members s WHERE s.local_id = c.local_id)
        FROM message_classes c JOIN messages m ON m.local_id = c.local_id
        WHERE c.arrival > ? ORDER BY c.arrival LIMIT ?
        """

    func arrivals(after sequence: Int64, limit: Int) throws -> [MailArrival] {
        let statement = try database.prepare(Self.arrivalsSQL).bind([.int(sequence), .int(Int64(limit))])
        var result: [MailArrival] = []
        while try statement.step() {
            guard let raw = statement.text(1), let id = MailMessageID(raw), let account = statement.text(2),
                  let home = statement.text(3).flatMap(MailCategory.init(rawValue:)) else { continue }
            result.append(MailArrival(sequence: Int64(statement.int(0)), id: id, account: MailAccountID(account), home: home,
                                      listID: statement.text(4), fromName: statement.text(5), fromAddress: statement.text(6),
                                      subject: statement.text(7), received: Date(timeIntervalSince1970: statement.double(8)),
                                      isUnread: statement.int(9) == 0, senderRule: statement.text(10),
                                      disposition: statement.text(11).flatMap(SenderDisposition.init(rawValue:)),
                                      spaces: Set((statement.text(12) ?? "").split(separator: ",").compactMap { MailSpaceID(String($0)) })))
        }
        return result
    }

    /// The folders a message is in, from this device's sync state.
    func mailboxes(of id: MailMessageID) throws -> [String] {
        let statement = try database.prepare("SELECT mailbox FROM message_mailboxes WHERE local_id = ? ORDER BY mailbox").bind([.text(id.rawValue)])
        var names: [String] = []
        while try statement.step() { if let name = statement.text(0) { names.append(name) } }
        return names
    }

    private static func idsAndAccounts(_ statement: SQLiteDatabase.Statement) throws -> [(id: MailMessageID, account: MailAccountID)] {
        var result: [(MailMessageID, MailAccountID)] = []
        while try statement.step() {
            if let raw = statement.text(0), let id = MailMessageID(raw), let account = statement.text(1) { result.append((id, MailAccountID(account))) }
        }
        return result
    }
}
