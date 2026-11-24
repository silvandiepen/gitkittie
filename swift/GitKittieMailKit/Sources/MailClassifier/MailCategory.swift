import Foundation
import MailCore

/// Where a message belongs in the window (Features.md: focused inbox and category views;
/// Classification.md, Taxonomy, "Default attention"). Every message has exactly one home;
/// All Mail shows every message whatever its home.
///
/// - `focused`: conversations, security mail that is not quarantined, transactions that need
///   doing or paying, urgent notifications, and everything uncertain (`unknown`, or not
///   classified yet). Uncertain mail is never hidden.
/// - `transactions`, `updates`, `subscriptions`, `promotions`: the rest of each purpose. The
///   Transactions view also lists the actionable transactions that live in Focused, so every
///   receipt and invoice is in one place.
/// - `quarantine`: spam and phishing, with review. Never deleted, never moved at the provider.
public enum MailCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case focused, transactions, updates, subscriptions, promotions, quarantine

    /// The home of a verdict.
    public static func home(purpose: MailPurpose, risk: MailRisk, urgency: MailUrgency) -> MailCategory {
        if risk.isQuarantined { return .quarantine }
        switch purpose {
        case .conversation, .security, .unknown: return .focused
        case .transaction: return urgency == .low ? .transactions : .focused
        case .notification: return urgency == .high ? .focused : .updates
        case .subscription: return .subscriptions
        case .promotion: return .promotions
        }
    }

    /// The purpose a category view lists besides its home messages (Transactions: every
    /// transaction that is not quarantined).
    public var purpose: MailPurpose? {
        switch self {
        case .transactions: .transaction
        case .updates: .notification
        case .subscriptions: .subscription
        case .promotions: .promotion
        case .focused, .quarantine: nil
        }
    }

    /// Unread mail here counts towards the badge and may notify (Classification.md,
    /// Notifications: promotions, newsletters and routine updates are silent).
    public var asksForAttention: Bool { self == .focused }
}

extension Classification {
    public var home: MailCategory { MailCategory.home(purpose: purpose, risk: risk, urgency: urgency) }
}
