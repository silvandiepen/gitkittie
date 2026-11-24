import Foundation
import MailClassifier
import MailCore
import MailStore

// Corrections and rules from the reader (GKM-017). A correction changes one message, at once,
// and is kept through upgrades; a rule is only ever made when you choose one. Nothing here
// changes anything at the provider: no move, no flag, no label (MAIL-007).

extension AppModel {
    /// "Move to Transactions" and the like: this message only.
    func move(_ id: MailMessageID, to purpose: MailPurpose) async {
        await changeClassification { try await $0.correct(id, purpose: purpose) }
    }

    /// "Not Phishing" / "Not Spam": clears the risk of this message only. The reader's own
    /// warnings about the sender and links stay, because they describe what is there.
    func clearRisk(_ id: MailMessageID) async {
        await changeClassification { try await $0.correct(id, risk: MailRisk.none) }
    }

    /// "Report Phishing": marks this message as phishing (Quarantine), here only.
    func markPhishing(_ id: MailMessageID) async {
        await changeClassification { try await $0.correct(id, risk: .phishing) }
    }

    /// Takes back your correction; the classifier decides again.
    func undoCorrection(_ id: MailMessageID) async {
        await changeClassification { try await $0.removeCorrection(of: id) }
    }

    /// The rule you chose after a correction: this sender, or this list, in this account.
    func addRule(_ scope: ClassificationRule.Scope, purpose: MailPurpose, account: MailAccountID) async {
        await changeClassification { try await $0.addRule(scope, purpose: purpose, account: account) }
    }

    func removeRule(id: String) async {
        await changeClassification { try await $0.removeRule(id: id) }
    }

    func classificationRules() async -> [ClassificationRule] {
        guard let store = mailStore else { return [] }
        do { return try await store.classificationRules() } catch { actionError = String(describing: error); return [] }
    }

    /// Your correction of this message, if any.
    func correction(of id: MailMessageID) async -> ClassificationCorrection? {
        guard let store = mailStore else { return nil }
        do { return try await store.correction(of: id) } catch { actionError = String(describing: error); return nil }
    }

    /// Your rule covering this message's sender or list, if you made one.
    func rule(for verdict: StoredVerdict) async -> ClassificationRule? {
        await classificationRules().last { rule in
            guard rule.account == verdict.account else { return false }
            switch rule.scope {
            case .sender(let address): return address == verdict.fromAddress
            case .list(let list): return list == verdict.listID
            }
        }
    }

    private func changeClassification(_ change: (MailStore) async throws -> Any?) async {
        guard let store = mailStore else { return }
        do {
            _ = try await change(store)
        } catch {
            actionError = String(describing: error)
        }
        await browser.refreshAfterClassificationChange()
        await attention.refresh(accounts: accounts, arrivals: .leave)
    }
}

// MARK: - Words

extension MailCategory {
    var title: String {
        switch self {
        case .focused: "Focused"
        case .transactions: "Transactions"
        case .updates: "Updates"
        case .subscriptions: "Subscriptions"
        case .promotions: "Promotions"
        case .quarantine: "Quarantine"
        }
    }

    var systemImage: String {
        switch self {
        case .focused: "tray"
        case .transactions: "creditcard"
        case .updates: "bell"
        case .subscriptions: "newspaper"
        case .promotions: "tag"
        case .quarantine: "exclamationmark.shield"
        }
    }

    /// What an empty view says.
    var emptyNote: String {
        switch self {
        case .focused: "Nothing needs you right now."
        case .transactions: "No receipts, orders or invoices."
        case .updates: "No updates."
        case .subscriptions: "No newsletters."
        case .promotions: "No offers."
        case .quarantine: "Nothing suspicious."
        }
    }
}

extension MailPurpose {
    /// The view a message of this purpose moves to, for "Move to …".
    var destinationTitle: String {
        switch self {
        case .conversation: "Conversations"
        case .transaction: "Transactions"
        case .security: "Security"
        case .notification: "Updates"
        case .subscription: "Subscriptions"
        case .promotion: "Promotions"
        case .unknown: "Not Sure"
        }
    }

    /// The purposes you can move a message to.
    static let correctable: [MailPurpose] = [.conversation, .transaction, .security, .notification, .subscription, .promotion]
}

/// "Why is this in Promotions?": the verdict in sentences.
enum VerdictText {
    /// One line under the sender: where it is and how sure.
    static func summary(_ verdict: StoredVerdict) -> String {
        let place = verdict.home.title
        let c = verdict.classification
        switch verdict.disposition {
        case .muted: return "Muted by your rule for this sender. Still in All Mail."
        case .archived: return "In \(place), archived silently by your rule for this sender."
        case .inbox: return "In Focused because of your rule for this sender."
        case nil: break
        }
        if verdict.isCorrected { return "In \(place) because you said so." }
        if c.risk == .phishing { return "In \(place): this looks like phishing." }
        if c.risk == .spam { return "In \(place): this looks like junk." }
        if c.purpose == .unknown { return "In \(place): not sure what this is, so it stays in view." }
        if c.confidence < 0.6 { return "In \(place), probably \(purposeWord(c.purpose))." }
        return "In \(place): \(purposeWord(c.purpose))."
    }

    static func purposeWord(_ purpose: MailPurpose) -> String {
        switch purpose {
        case .conversation: "a conversation"
        case .transaction: "a receipt, order, invoice or booking"
        case .security: "account security"
        case .notification: "an update"
        case .subscription: "a newsletter or mailing list"
        case .promotion: "an offer"
        case .unknown: "not sure"
        }
    }

    /// Each reason the classifier gave, in words, without repeats. Reasons with no sentence
    /// (internal steps) are left out; the stored codes keep all of them.
    static func reasons(_ verdict: StoredVerdict) -> [String] {
        var seen = Set<String>()
        return verdict.classification.reasons.compactMap { sentence($0, verdict: verdict) }.filter { seen.insert($0).inserted }
    }

    static func sentence(_ reason: ReasonCode, verdict: StoredVerdict) -> String? {
        let detail = verdict.classification.evidence.first { $0.reason == reason }?.detail ?? ""
        switch reason {
        case .providerSpam, .providerJunkLabel, .providerJunkFolder: return "Your mail provider marked it as junk."
        case .providerPhishing: return "Your mail provider marked it as phishing."
        case .providerNotSpam: return "Your mail provider marked it as not junk."
        case .listID, .listUnsubscribe, .listUnsubscribePost, .bulkPrecedence: return "It was sent to a mailing list."
        case .autoSubmitted: return "It was sent automatically."
        case .threadReply: return "It’s a reply in a conversation."
        case .listDiscussion: return "Someone posted it to a discussion list."
        case .personalSender: return "A person wrote it, not a company’s system."
        case .knownCorrespondent: return "You’ve written to this sender."
        case .roleAddress: return "It comes from a company address (\(detail)@), not a person."
        case .replyToMismatch: return "Replies would go to a different domain (\(detail))."
        case .displayNameSpoof: return "The sender’s name pretends to be someone else (\(detail))."
        case .lookalikeSender: return "The sender’s domain imitates one you know (\(detail))."
        case .authTrustedPass: return "Your provider confirmed the sender’s domain."
        case .authTrustedFail: return "Your provider could not confirm the sender’s domain."
        case .linkTextMismatch: return "A link shows one address but goes to another (\(detail))."
        case .trackedLink: return "Its links go through the sender’s mailing service to count clicks."
        case .lookalikeLink: return "A link goes to a domain that imitates one you know (\(detail))."
        case .dangerousAttachment: return "It has an attachment that can run code (\(detail))."
        case .spamPhrases: return "It uses wording typical of scams."
        case .hostileStructure: return "The message is built in an unusual, possibly hostile way."
        case .userOverride: return "You corrected this message."
        case .userRuleList: return "Your rule for this list."
        case .userRuleSender, .userRuleDomain: return "Your rule for this sender."
        case .securityCode: return "It contains a sign-in or verification code."
        case .securityAlert: return "It’s about your account’s security (“\(detail)”)."
        case .delivery: return "It’s a delivery update (“\(detail)”)."
        case .transaction: return "It’s a record of a purchase or payment (“\(detail)”)."
        case .transactionDue: return "It’s a bill to pay or a booking (“\(detail)”)."
        case .transactionAction: return "It asks you to act on a payment (“\(detail)”)."
        case .offerNotOrder: return "It mentions an order, but it’s an offer with no order number."
        case .moneyAmount: return "It mentions an amount of money."
        case .codeHost: return "It’s a notification from a code repository."
        case .notificationSender: return "It comes from a notification address."
        case .promotion: return "Its subject is an offer (“\(detail)”)."
        case .newsletter: return "Its subject reads like a newsletter (“\(detail)”)."
        case .reviewRequested: return "It asks for your review or mentions you."
        case .personalFallback: return "It looks like a person wrote it."
        case .insufficientEvidence: return "Nothing showed what it is."
        case .riskyWithoutPurpose: return "It looks risky and nothing showed what it is."
        default: return nil
        }
    }
}
