import Foundation
import MailClassifier
import MailCore

// Active organisation and retention (GKM-031; Features.md, Organisation modes; Classification.md,
// Retention; decisions MAIL-115..119).
//
// Virtual mode is the default (MAIL-007): nothing the app decides by itself moves mail at the
// provider. Active mode is opt-in twice: per account, and per rule or retention policy. A policy
// is always shown as a dry run first (the cleanup preview, MAIL-060: exactly what would move and
// what is protected) and runs only once you turn it on; from then on it runs after each sync, on
// one device only (the account's coordinating device), and only while that device is online and
// its earlier changes have reached the provider. Every run goes through the action journal
// (MAIL-034) and is written to an audit log without mail content, from which it can be undone.
// Nothing is ever deleted permanently: a policy archives or moves to Trash.

/// A device, as organisation settings and the audit log name it.
public struct OrganisationDevice: Codable, Sendable, Hashable {
    /// The device's id (`StoreLocations.deviceIdentifier()`).
    public var id: String
    /// "Mac", "iPhone", "iPad": what the other devices say runs the work.
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Active mode for one account: off by default (virtual mode, MAIL-007).
public struct AccountOrganisation: Codable, Sendable, Equatable {
    public var account: MailAccountID
    /// Rules and retention policies of this account may move mail at the provider.
    public var isActive: Bool
    /// The one device that runs automatic work for this account. Another device pauses.
    public var coordinator: OrganisationDevice?
    public var updatedAt: Date

    public init(account: MailAccountID, isActive: Bool = false, coordinator: OrganisationDevice? = nil, updatedAt: Date = Date()) {
        self.account = account
        self.isActive = isActive
        self.coordinator = coordinator
        self.updatedAt = updatedAt
    }
}

/// What a retention policy does with mail past its age. Never a permanent delete.
public enum RetentionAction: String, Codable, Sendable, Hashable, CaseIterable {
    /// Out of the inbox into the account's archive folder (MAIL-036).
    case archive
    /// Into the account's Trash, which the provider may empty by its own rules.
    case trash
}

/// Keep mail of one category for a number of days, then archive it or move it to Trash.
public struct RetentionPolicy: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var account: MailAccountID
    /// Subscriptions, Promotions or Updates (`RetentionPolicy.categories`).
    public var category: MailCategory
    public var days: Int
    public var action: RetentionAction
    /// Off: a dry run only. On: it runs after each sync on the coordinating device.
    public var isActive: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString.lowercased(), account: MailAccountID, category: MailCategory, days: Int? = nil,
                action: RetentionAction = .archive, isActive: Bool = false, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.account = account
        self.category = category
        self.days = days ?? Self.suggestedDays(for: category) ?? 90
        self.action = action
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The categories a policy can be made for. Focused and Transactions keep mail indefinitely
    /// (conversations, receipts, orders, invoices); Quarantine is never moved at the provider
    /// (MAIL-059), so there is no spam policy; verification codes are account security mail,
    /// which is always protected (MAIL-115).
    public static let categories: [MailCategory] = [.subscriptions, .promotions, .updates]

    /// Classification.md, Retention: newsletters 90 days, promotions and routine updates 30.
    public static func suggestedDays(for category: MailCategory) -> Int? {
        switch category {
        case .subscriptions: 90
        case .promotions, .updates: 30
        case .focused, .transactions, .quarantine: nil
        }
    }

    /// The ages a policy can be set to.
    public static let dayChoices = [7, 14, 30, 60, 90, 180, 365]

    /// The cleanup group the policy acts on: its category, older than its days.
    public var group: CleanupGroupID { CleanupGroupID(account: account, kind: .olderThan(category: category, days: days)) }
}

/// Your organisation settings: user data in `metadata/organisation.json`, beside the sender
/// rules, so GKM-026 can sync it to your other devices as its own record type.
public struct OrganisationSettings: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version = Self.currentVersion
    public var accounts: [AccountOrganisation] = []
    public var retention: [RetentionPolicy] = []

    public init(accounts: [AccountOrganisation] = [], retention: [RetentionPolicy] = []) {
        self.accounts = accounts
        self.retention = retention
    }

    public func account(_ id: MailAccountID) -> AccountOrganisation? { accounts.first { $0.account == id } }

    /// Active mode is on for the account.
    public func isActive(_ id: MailAccountID) -> Bool { account(id)?.isActive == true }

    public func policies(for account: MailAccountID) -> [RetentionPolicy] { retention.filter { $0.account == account } }

    /// Replaces (or adds) the account's entry.
    public mutating func set(_ entry: AccountOrganisation) {
        if let index = accounts.firstIndex(where: { $0.account == entry.account }) { accounts[index] = entry } else { accounts.append(entry) }
    }

    /// Replaces (or adds) a policy.
    public mutating func set(_ policy: RetentionPolicy) {
        if let index = retention.firstIndex(where: { $0.id == policy.id }) { retention[index] = policy } else { retention.append(policy) }
    }

    static func url(in deviceFolder: URL) -> URL {
        deviceFolder.appendingPathComponent("metadata", isDirectory: true).appendingPathComponent("organisation.json")
    }

    /// A missing file is the default (virtual mode everywhere); a damaged or newer one is an
    /// error, never replaced: it holds your decisions.
    static func load(from url: URL) throws -> OrganisationSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return OrganisationSettings() }
        let settings = try JSONCoding.decoder.decode(OrganisationSettings.self, from: Data(contentsOf: url))
        guard settings.version <= Self.currentVersion else { throw MailStoreError.unsupportedMetadataVersion(settings.version) }
        return settings
    }
}

// MARK: - The audit log

/// What made a run.
public enum OrganisationSource: Codable, Sendable, Hashable {
    /// A retention policy, with the category and age it had when it ran.
    case retention(policy: String, category: MailCategory, days: Int)
    /// A sender rule set to archive at your provider (MAIL-054), by its id.
    case senderRule(String)
}

/// Whether you started it or the app did.
public enum OrganisationTrigger: String, Codable, Sendable, Hashable {
    /// You confirmed it: a policy turned on from its dry run, a rule applied.
    case confirmed
    /// After a sync, on the coordinating device.
    case automatic
}

/// One run of active organisation, without mail content: no subjects, addresses or text, only
/// the store's own message ids and the folders they moved between, so it can be undone.
public struct OrganisationAuditEntry: Codable, Sendable, Equatable, Identifiable {
    /// One move at the provider: what Undo sends back.
    public struct Move: Codable, Sendable, Equatable {
        public var message: MailMessageID
        public var from: String
        public var to: String
    }

    /// The operation id.
    public var id: String
    public var date: Date
    public var device: OrganisationDevice
    public var account: MailAccountID
    public var source: OrganisationSource
    public var trigger: OrganisationTrigger
    public var action: RetentionAction
    /// Messages moved.
    public var count: Int
    /// The journal batch (MAIL-034) that holds the moves.
    public var batch: String
    public var moves: [Move]
    /// When it was undone, and how many messages went back.
    public var undoneAt: Date?
    public var restored: Int?

    public var isUndone: Bool { undoneAt != nil }
}

/// The audit log file: `metadata/organisation-audit.json`, newest last.
struct OrganisationAuditLog: Codable, Equatable {
    static let version = 1
    /// Entries kept; older ones are dropped (MAIL-118).
    static let limit = 1000
    var version = Self.version
    var entries: [OrganisationAuditEntry] = []

    static func url(in deviceFolder: URL) -> URL {
        deviceFolder.appendingPathComponent("metadata", isDirectory: true).appendingPathComponent("organisation-audit.json")
    }

    static func load(from url: URL) throws -> OrganisationAuditLog {
        guard FileManager.default.fileExists(atPath: url.path) else { return OrganisationAuditLog() }
        let log = try JSONCoding.decoder.decode(OrganisationAuditLog.self, from: Data(contentsOf: url))
        guard log.version <= Self.version else { throw MailStoreError.unsupportedMetadataVersion(log.version) }
        return log
    }
}

public enum OrganisationError: Error, Equatable, CustomStringConvertible {
    /// Active mode is off for the account: nothing may move.
    case accountNotActive
    /// An automatic run on a device that is not the account's coordinating device.
    case notCoordinator
    /// The policy was turned off or changed since it was previewed.
    case policyChanged
    /// The entry was made on another device: its message ids and journal are that device's.
    case madeOnAnotherDevice(String)
    case alreadyUndone
    case entryNotFound

    public var description: String {
        switch self {
        case .accountNotActive: "Active organisation is off for this account, so nothing was moved."
        case .notCoordinator: "Another device runs active organisation for this account, so nothing was moved here."
        case .policyChanged: "The policy changed since it was previewed, so nothing was moved."
        case .madeOnAnotherDevice(let name): "This was done on your \(name). Undo it there."
        case .alreadyUndone: "This was undone already."
        case .entryNotFound: "This step is no longer in the history."
        }
    }
}
