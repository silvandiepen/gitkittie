import Foundation

// The classification taxonomy (Classification.md, Taxonomy). Purpose, risk and urgency are
// separate dimensions (MAIL-008): marketing is not spam, and a phishing invoice keeps the
// purpose it claims while its risk sends it to review.

/// What a message is for.
public enum MailPurpose: String, CaseIterable, Codable, Sendable {
    case conversation, transaction, security, notification, subscription, promotion, unknown

    /// Conversations, transactions and security mail must never be suppressed as marketing.
    public var isImportant: Bool { self == .conversation || self == .transaction || self == .security }
}

/// How dangerous a message looks. `none` means no risk evidence was found, not that the
/// message is proven safe.
public enum MailRisk: String, CaseIterable, Codable, Sendable {
    case none, suspicious, spam, phishing

    /// Spam and phishing go to quarantine with review; suspicious mail stays visible with a warning.
    public var isQuarantined: Bool { self == .spam || self == .phishing }
}

/// How much attention a message asks for.
public enum MailUrgency: String, CaseIterable, Codable, Sendable {
    case low, normal, high
}
