import Foundation
import MailCore

/// The classifier's verdict for one message (Classification.md, step 6).
public struct Classification: Sendable, Equatable, Codable {
    public var purpose: MailPurpose
    public var risk: MailRisk
    public var urgency: MailUrgency
    /// How sure the purpose is, 0...1. Low confidence keeps the message visible.
    public var confidence: Double
    /// Every reason that contributed, in the order it was found, without duplicates.
    public var reasons: [ReasonCode]
    public var evidence: [Evidence]
    public var ruleSetVersion: String
}

/// A stable identifier for why the classifier decided something. Stored with corrections and
/// shown to the user, so never rename one; add a new code instead.
public struct ReasonCode: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    // Step 1: provider
    public static let providerSpam = ReasonCode(rawValue: "provider.spam")
    public static let providerPhishing = ReasonCode(rawValue: "provider.phishing")
    public static let providerNotSpam = ReasonCode(rawValue: "provider.not-spam")
    public static let providerJunkLabel = ReasonCode(rawValue: "provider.junk-label")
    public static let providerJunkFolder = ReasonCode(rawValue: "provider.junk-folder")
    // Step 2: header signals
    public static let listID = ReasonCode(rawValue: "header.list-id")
    public static let listUnsubscribe = ReasonCode(rawValue: "header.list-unsubscribe")
    public static let listUnsubscribePost = ReasonCode(rawValue: "header.list-unsubscribe-post")
    public static let bulkPrecedence = ReasonCode(rawValue: "header.precedence-bulk")
    public static let autoSubmitted = ReasonCode(rawValue: "header.auto-submitted")
    public static let threadReply = ReasonCode(rawValue: "thread.reply")
    public static let listDiscussion = ReasonCode(rawValue: "list.discussion")
    public static let personalSender = ReasonCode(rawValue: "sender.personal")
    public static let knownCorrespondent = ReasonCode(rawValue: "sender.known-correspondent")
    public static let roleAddress = ReasonCode(rawValue: "sender.role-address")
    public static let replyToMismatch = ReasonCode(rawValue: "sender.reply-to-mismatch")
    public static let displayNameSpoof = ReasonCode(rawValue: "sender.display-name-spoof")
    public static let lookalikeSender = ReasonCode(rawValue: "sender.lookalike-domain")
    public static let authTrustedPass = ReasonCode(rawValue: "auth.trusted-pass")
    public static let authTrustedFail = ReasonCode(rawValue: "auth.trusted-fail")
    public static let authUntrustedIgnored = ReasonCode(rawValue: "auth.untrusted-ignored")
    public static let linkTextMismatch = ReasonCode(rawValue: "content.link-text-mismatch")
    public static let trackedLink = ReasonCode(rawValue: "content.tracked-link")
    public static let lookalikeLink = ReasonCode(rawValue: "content.lookalike-link")
    public static let dangerousAttachment = ReasonCode(rawValue: "content.dangerous-attachment")
    public static let spamPhrases = ReasonCode(rawValue: "content.spam-phrases")
    public static let hostileStructure = ReasonCode(rawValue: "structure.hostile")
    // Step 3: user
    public static let userOverride = ReasonCode(rawValue: "user.override")
    public static let userRuleList = ReasonCode(rawValue: "user.rule.list")
    public static let userRuleSender = ReasonCode(rawValue: "user.rule.sender")
    public static let userRuleDomain = ReasonCode(rawValue: "user.rule.domain")
    // Step 4: templates
    public static let securityCode = ReasonCode(rawValue: "template.security-code")
    public static let securityAlert = ReasonCode(rawValue: "template.security-alert")
    public static let delivery = ReasonCode(rawValue: "template.delivery")
    public static let transaction = ReasonCode(rawValue: "template.transaction")
    public static let moneyAmount = ReasonCode(rawValue: "template.money-amount")
    public static let transactionAction = ReasonCode(rawValue: "template.transaction-action")
    public static let transactionDue = ReasonCode(rawValue: "template.transaction-due")
    public static let offerNotOrder = ReasonCode(rawValue: "template.offer-not-order")
    public static let codeHost = ReasonCode(rawValue: "template.code-host")
    public static let notificationSender = ReasonCode(rawValue: "template.notification-sender")
    public static let promotion = ReasonCode(rawValue: "template.promotion")
    public static let newsletter = ReasonCode(rawValue: "template.newsletter")
    public static let reviewRequested = ReasonCode(rawValue: "template.review-requested")
    // Fallbacks
    public static let personalFallback = ReasonCode(rawValue: "purpose.personal-fallback")
    public static let insufficientEvidence = ReasonCode(rawValue: "purpose.insufficient-evidence")
    public static let riskyWithoutPurpose = ReasonCode(rawValue: "purpose.risky-without-purpose")
}

/// What a reason was based on: the field and a short excerpt. Local only; never logged.
public struct Evidence: Sendable, Equatable, Codable {
    public var reason: ReasonCode
    /// A header name, "subject", "body", "link", "attachment", "provider" or "rule".
    public var field: String
    public var detail: String
    public init(reason: ReasonCode, field: String, detail: String) {
        self.reason = reason
        self.field = field
        self.detail = detail
    }
}
