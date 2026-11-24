import Foundation
import MailClassifier
import MailCore

// Sender and list rules (GKM-019; MAIL-054, MAIL-055). What you decided about a whole sender or
// mailing list: keep it in Focused, archive it silently, give it a category, mute it, keep only
// its transactions, keep only its latest digest. They are user data like the corrections, in
// their own file `<device folder>/metadata/sender-rules.json`, records with a stable id, account
// and dates, so GKM-026 can sync them through private CloudKit apart from the corrections.
//
// Rules never act on risky mail (spam, phishing, suspicious), never hide account-security mail,
// and never override a correction you made to one message. Muting and silent archiving are
// virtual: the message keeps its folders and flags at the provider unless the rule also asks to
// archive there, which the app sends through the action journal like any other action.

/// What a rule is about: one mailing list or one sender address, in one account.
///
/// A List-ID is easy to copy, so a list rule also remembers the organisation that sent the list
/// when the rule was made, and only matches mail from it. An address rule matches the From
/// address, never the display name.
public enum SenderScope: Codable, Sendable, Hashable {
    /// A List-ID (lowercased, without angle brackets) and the sender organisation it comes from.
    case list(id: String, organisation: String?)
    /// A From address, lowercased.
    case sender(String)

    public var listID: String? {
        if case .list(let id, _) = self { return id }
        return nil
    }

    public var address: String? {
        if case .sender(let address) = self { return address }
        return nil
    }

    /// The List-ID or the address, for display.
    public var name: String {
        switch self {
        case .list(let id, _): id
        case .sender(let address): address
        }
    }

    func matches(address: String?, listID: String?, organisation: String?) -> Bool {
        switch self {
        case .list(let id, let owner):
            guard listID == id else { return false }
            return owner == nil || owner == organisation
        case .sender(let mine):
            // Every message from the address, on a list or not; your order decides between an
            // address rule and a list rule that both match.
            return address == mine
        }
    }
}

/// What a rule does with the mail it matches.
public enum SenderRuleAction: Codable, Sendable, Hashable {
    /// Always in Focused (never risky mail).
    case inbox
    /// Out of Focused and silent, still in its category view. Virtual unless the rule also archives at the provider.
    case silentArchive
    /// Every message gets this purpose (like a correction, for the whole sender or list).
    case category(MailPurpose)
    /// Out of Focused and the category views, silent; still in All Mail, its account and folders.
    case mute
    /// Receipts, orders, invoices and account-security mail stay; everything else is muted.
    case keepTransactionsOnly
    /// The newest message stays; every older one is muted.
    case keepLatestOnly

    /// Silent archive and mutes can also archive at the provider, if you ask for it.
    public var canArchiveAtProvider: Bool {
        switch self {
        case .silentArchive, .mute, .keepTransactionsOnly, .keepLatestOnly: true
        case .inbox, .category: false
        }
    }
}

/// Where a rule put a message, besides its category.
public enum SenderDisposition: String, Codable, Sendable, Hashable {
    /// Kept in Focused by an inbox rule.
    case inbox
    /// Silently archived: out of Focused, still in its category view.
    case archived
    /// Muted: out of Focused and the category views.
    case muted
}

/// A rule of yours for one sender or list.
public struct SenderRule: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var account: MailAccountID
    public var scope: SenderScope
    public var action: SenderRuleAction
    public var isEnabled: Bool
    /// Also archive matching mail at the provider (through the action journal). Off by default:
    /// a rule is virtual unless you choose otherwise.
    public var archiveAtProvider: Bool
    /// Messages you took out of the rule in its preview, by content fingerprint.
    public var excluded: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString.lowercased(), account: MailAccountID, scope: SenderScope, action: SenderRuleAction,
                isEnabled: Bool = true, archiveAtProvider: Bool = false, excluded: [String] = [],
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.account = account
        self.scope = scope
        self.action = action
        self.isEnabled = isEnabled
        self.archiveAtProvider = archiveAtProvider && action.canArchiveAtProvider
        self.excluded = excluded
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func matches(_ facts: SenderFacts) -> Bool {
        isEnabled && account == facts.account
            && scope.matches(address: facts.address, listID: facts.listID, organisation: facts.organisation)
            && !excluded.contains(facts.fingerprint)
    }
}

/// Why a rule matched a message but left it as it was.
public enum SenderRuleProtection: String, Codable, Sendable, Hashable {
    /// Spam, phishing or suspicious: rules never act on risky mail.
    case risky
    /// You corrected this message yourself.
    case corrected
    /// Account security mail is never hidden.
    case security
    /// Kept by "keep transactions only".
    case transaction
    /// Kept by "keep latest only": the newest message.
    case latest
}

/// What the winning rule did to one message.
public enum SenderRuleEffect: Sendable, Equatable {
    case disposition(SenderDisposition)
    case purpose(MailPurpose)
    case protected(SenderRuleProtection)
}

/// The identity and verdict of a message, as rules see them.
struct SenderFacts {
    var account: MailAccountID
    var address: String?
    var listID: String?
    var organisation: String?
    var fingerprint: String
}

/// Rule order and matching: the first enabled rule, in your order, whose sender or list matches
/// and that does not exclude the message, wins. Later matching rules are listed as "also
/// matched", so the reader can say why the winner won.
enum SenderRuleEngine {
    static func matching(_ rules: [SenderRule], _ facts: SenderFacts) -> [SenderRule] {
        rules.filter { $0.matches(facts) }
    }

    /// The disposition the winning rule gives a classified message. `isLatest` says whether it
    /// is the newest message the rule matches (for keep latest only).
    static func effect(of rule: SenderRule, classification: Classification, isCorrected: Bool, isLatest: Bool) -> SenderRuleEffect {
        if case .category(let purpose) = rule.action {
            // The classifier applied it (rules never lower risk); a correction still wins.
            return isCorrected ? .protected(.corrected) : .purpose(purpose)
        }
        if classification.risk != .none { return .protected(.risky) }
        if isCorrected { return .protected(.corrected) }
        switch rule.action {
        case .inbox: return .disposition(.inbox)
        case .category: return .protected(.corrected) // handled above
        case .silentArchive, .mute, .keepTransactionsOnly, .keepLatestOnly:
            if classification.purpose == .security { return .protected(.security) }
            switch rule.action {
            case .silentArchive: return .disposition(.archived)
            case .keepTransactionsOnly:
                return classification.purpose == .transaction ? .protected(.transaction) : .disposition(.muted)
            case .keepLatestOnly:
                return isLatest ? .protected(.latest) : .disposition(.muted)
            default: return .disposition(.muted)
            }
        }
    }

    /// The category view a message lives in once a rule placed it.
    static func home(classifierHome: MailCategory, effect: SenderRuleEffect?) -> MailCategory {
        if case .disposition(.inbox) = effect, classifierHome != .quarantine { return .focused }
        return classifierHome
    }
}

/// The file the sender rules live in. The array order is the rule order.
struct SenderRuleSet: Codable, Equatable {
    static let version = 1
    var version = Self.version
    var rules: [SenderRule] = []

    static func url(in deviceFolder: URL) -> URL {
        deviceFolder.appendingPathComponent("metadata", isDirectory: true).appendingPathComponent("sender-rules.json")
    }

    /// A missing file is empty; a damaged or newer one is an error, never replaced: it holds your decisions.
    static func load(from url: URL) throws -> SenderRuleSet {
        guard FileManager.default.fileExists(atPath: url.path) else { return SenderRuleSet() }
        let set = try JSONCoding.decoder.decode(SenderRuleSet.self, from: Data(contentsOf: url))
        guard set.version <= Self.version else { throw MailStoreError.unsupportedMetadataVersion(set.version) }
        return set
    }

    func save(to url: URL, writer: AtomicWriter) throws {
        try writer.write(JSONCoding.prettyEncoder.encode(self), to: url)
    }
}
