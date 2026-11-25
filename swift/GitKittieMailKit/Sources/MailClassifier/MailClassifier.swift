import Foundation
import MailCore

/// Purpose, risk and urgency with reason codes (GKM-007). Deterministic rules only, following
/// Classification.md steps 1–4: provider verdicts, safe header signals, user overrides and
/// scoped rules, then templates. No model, no network, no side effects.
///
/// Purpose and risk are decided separately (MAIL-008). A risky message keeps the purpose it
/// claims (a fake invoice is a "transaction" with risk `phishing`); its risk is what sends it
/// to review. Important purposes are decided before marketing ones, so a receipt with an offer
/// or bulk headers stays a transaction, and when nothing fits the answer is `unknown`, which
/// stays visible.
///
/// gkm-rules-2 (GKM-017): organisation domains from the Public Suffix List; the provider's junk
/// folder counts as its verdict; a sender's own click-tracker is not a deceptive link; a person
/// posting to a discussion list is a conversation; a person mentioning a password or an order is
/// not a security alert or a receipt; transactions carry urgency (act now, pay or attend, keep).
public struct MailClassifier: Sendable {
    /// Bump when any rule or template list changes, so stored verdicts can be re-evaluated.
    public static let ruleSetVersion = "gkm-rules-2"

    public var context: ClassificationContext

    public init(context: ClassificationContext = ClassificationContext()) { self.context = context }

    public func classify(_ message: ClassificationInput) -> Classification {
        var trace = Trace()
        let signals = Signals(message: message, context: context, trace: &trace)
        let risk = assessRisk(signals, trace: &trace)

        var (purpose, confidence) = decidePurpose(message, signals, trace: &trace)
        if risk.isQuarantined && trace.reasons.last == .personalFallback {
            purpose = .unknown
            confidence = 0.4
            trace.add(.riskyWithoutPurpose, "rule", "risky mail with no stronger purpose evidence")
        }
        var finalPurpose = purpose
        var finalRisk = risk
        var chosenUrgency: MailUrgency?
        if let rule = matchingRule(message, signals) {
            finalPurpose = rule.purpose
            confidence = 0.95
            if let ruleUrgency = rule.urgency, !finalRisk.isQuarantined { chosenUrgency = ruleUrgency }
            let code: ReasonCode = switch rule.scope {
            case .listID: .userRuleList
            case .senderAddress: .userRuleSender
            case .senderDomain: .userRuleDomain
            }
            trace.add(code, "rule", rule.id)
        }
        if let id = message.messageID, let override = context.overrides.first(where: { $0.messageID == id }) {
            if let p = override.purpose { finalPurpose = p }
            if let r = override.risk { finalRisk = r }
            if let u = override.urgency { chosenUrgency = u }
            confidence = 1
            trace.add(.userOverride, "rule", id)
        }
        // Urgency follows the final purpose and risk, so a corrected message ("not phishing",
        // "move to Transactions") gets the urgency it would have had, unless one was chosen.
        let urgency = finalRisk.isQuarantined ? .low
            : chosenUrgency ?? decideUrgency(purpose: finalPurpose, risk: finalRisk, signals: signals, trace: &trace)

        return Classification(purpose: finalPurpose, risk: finalRisk, urgency: urgency, confidence: confidence,
                              reasons: trace.reasons, evidence: trace.evidence, ruleSetVersion: Self.ruleSetVersion)
    }

    // MARK: - Step 3: scoped rules

    private func matchingRule(_ message: ClassificationInput, _ signals: Signals) -> ScopedRule? {
        let candidates = context.rules.filter { rule in
            guard rule.isEnabled else { return false }
            switch rule.scope {
            case .listID(let id):
                return signals.listIdentity.map { $0 == id.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) } ?? false
            case .senderAddress(let address):
                return signals.fromAddress == address.lowercased()
            case .senderDomain(let domain):
                let d = domain.lowercased()
                return signals.fromDomain.map { $0 == d || $0.hasSuffix("." + d) } ?? false
            }
        }
        return candidates.min { a, b in
            if a.scope.specificity != b.scope.specificity { return a.scope.specificity > b.scope.specificity }
            if a.order != b.order { return a.order < b.order }
            return a.id < b.id
        }
    }

    // MARK: - Risk

    private func assessRisk(_ s: Signals, trace: inout Trace) -> MailRisk {
        if s.providerVerdict == .phishing { return .phishing }
        let claimsCredentialsOrMoney = s.securityTemplate != nil || s.transactionTerm != nil || s.securityClaim
        if s.displayNameSpoof || s.lookalikeSender != nil || s.lookalikeLink != nil || s.linkTextMismatch || s.dangerousAttachment {
            return .phishing
        }
        if claimsCredentialsOrMoney && (s.authFailed || s.replyToMismatch) { return .phishing }
        if s.providerVerdict == .spam || s.providerJunkLabel || s.spamPhraseCount >= 2 { return .spam }
        if s.authFailed || !s.structureFlags.isEmpty { return .suspicious }
        return .none
    }

    // MARK: - Purpose

    private func decidePurpose(_ m: ClassificationInput, _ s: Signals, trace: inout Trace) -> (MailPurpose, Double) {
        let personalHeaders = !s.hasListSignals && !s.autoSubmitted

        if s.knownCorrespondent && personalHeaders {
            return (.conversation, 0.85)
        }
        // A person replying is talking, whatever the subject says ("Re: the wifi password").
        if s.personalSender && s.isReply {
            trace.add(.personalSender, "From", s.fromLocalPart)
            return (.conversation, 0.8)
        }
        if let template = s.securityTemplate {
            trace.add(template.reason, template.field, template.term)
            return (.security, template.reason == .securityCode ? 0.9 : 0.8)
        }
        if let term = s.deliveryTerm {
            trace.add(.delivery, "subject", term)
            return (.notification, 0.8)
        }
        if let term = s.transactionTerm {
            if Templates.weakTransaction.contains(term), let offer = s.promotionTerm, !s.hasOrderReference {
                trace.add(.offerNotOrder, "subject", "\(term) + \(offer)")
            } else {
                switch s.transactionKind {
                case .action: trace.add(.transactionAction, "subject", term)
                case .due: trace.add(.transactionDue, "subject", term)
                case .record: trace.add(.transaction, "subject", term)
                }
                if s.hasMoneyAmount { trace.add(.moneyAmount, "body", "amount") }
                return (.transaction, s.hasMoneyAmount ? 0.9 : 0.75)
            }
        }
        if s.isReply && personalHeaders {
            return (.conversation, 0.8)
        }
        if s.autoSubmitted || s.codeHost || s.notificationSender {
            if s.codeHost { trace.add(.codeHost, "subject", "repository notification") }
            if s.notificationSender { trace.add(.notificationSender, "From", s.fromLocalPart) }
            return (.notification, s.codeHost ? 0.85 : 0.75)
        }
        // A discussion list (it accepts posts) carrying a person's message, not a campaign.
        if s.acceptsPosts && !s.isRoleAddress && !s.oneClickUnsubscribe && s.promotionTerm == nil && !s.autoSubmitted {
            trace.add(.listDiscussion, "List-Post", s.listPost ?? "")
            return (.conversation, s.isReply ? 0.8 : 0.7)
        }
        if s.hasListSignals {
            if let term = s.promotionTerm {
                trace.add(.promotion, "subject", term)
                return (.promotion, 0.9)
            }
            if let term = s.newsletterTerm { trace.add(.newsletter, "subject", term) }
            return (.subscription, s.newsletterTerm == nil ? 0.7 : 0.85)
        }
        if let term = s.promotionTerm {
            trace.add(.promotion, "subject", term)
            return (.promotion, 0.7)
        }
        if let term = s.newsletterTerm {
            trace.add(.newsletter, "subject", term)
            return (.subscription, 0.6)
        }
        if !s.isRoleAddress && s.fromAddress != nil && !s.bodyIsEmpty {
            trace.add(.personalFallback, "From", "individual sender, no bulk or automation signals")
            return (.conversation, 0.55)
        }
        trace.add(.insufficientEvidence, "rule", "no rule matched")
        return (.unknown, 0.3)
    }

    // MARK: - Urgency

    private func decideUrgency(purpose: MailPurpose, risk: MailRisk, signals: Signals, trace: inout Trace) -> MailUrgency {
        if risk.isQuarantined { return .low }
        switch purpose {
        case .security:
            return risk == .none ? .high : .normal
        case .notification:
            if signals.reviewRequested {
                trace.add(.reviewRequested, "header", "review requested or mention")
                return .normal
            }
            return .low
        case .subscription, .promotion:
            return .low
        case .transaction:
            // Without a transaction template (a rule or an override set the purpose) it stays normal.
            guard signals.transactionTerm != nil else { return .normal }
            switch signals.transactionKind {
            case .action: return .high
            case .due: return .normal
            case .record: return .low
            }
        case .conversation, .unknown:
            return .normal
        }
    }
}

// MARK: - Signals (steps 1, 2 and 4)

struct Trace {
    var reasons: [ReasonCode] = []
    var evidence: [Evidence] = []

    mutating func add(_ reason: ReasonCode, _ field: String, _ detail: String) {
        if !reasons.contains(reason) { reasons.append(reason) }
        evidence.append(Evidence(reason: reason, field: field, detail: String(detail.prefix(120))))
    }
}

private struct Signals {
    struct Template { var reason: ReasonCode; var field: String; var term: String }

    var fromAddress: String?
    var fromDomain: String?
    var fromOrganisation: String?
    var fromLocalPart = ""
    var listIdentity: String?
    var hasListSignals = false
    var autoSubmitted = false
    var isReply = false
    var knownCorrespondent = false
    var isRoleAddress = false
    var bodyIsEmpty = true
    var providerVerdict: ProviderSignals.Verdict?
    var providerJunkLabel = false
    var authFailed = false
    var replyToMismatch = false
    var displayNameSpoof = false
    var lookalikeSender: String?
    var lookalikeLink: String?
    var linkTextMismatch = false
    var dangerousAttachment = false
    var spamPhraseCount = 0
    var structureFlags: Set<StructureFlag> = []
    enum TransactionKind { case action, due, record }

    var securityTemplate: Template?
    /// The subject or body claims to be about credentials, whoever sent it (for risk).
    var securityClaim = false
    var deliveryTerm: String?
    var transactionTerm: String?
    var transactionKind = TransactionKind.record
    var hasOrderReference = false
    /// A person, not a function or a mailing machine: no role address, list or automation headers.
    var personalSender = false
    var listPost: String?
    var acceptsPosts = false
    var oneClickUnsubscribe = false
    var hasMoneyAmount = false
    var codeHost = false
    var notificationSender = false
    var reviewRequested = false
    var promotionTerm: String?
    var newsletterTerm: String?

    init(message m: ClassificationInput, context: ClassificationContext, trace: inout Trace) {
        // Step 1: provider.
        if let provider = m.provider {
            providerVerdict = provider.verdict
            switch provider.verdict {
            case .spam: trace.add(.providerSpam, "provider", "spam verdict")
            case .phishing: trace.add(.providerPhishing, "provider", "phishing verdict")
            case .notSpam: trace.add(.providerNotSpam, "provider", "not-spam verdict")
            case nil: break
            }
            if let junk = provider.labels.first(where: { Templates.junkLabels.contains($0.lowercased()) }) {
                providerJunkLabel = true
                trace.add(.providerJunkLabel, "provider", junk)
            } else if let folder = provider.folders.first(where: Signals.isJunkFolder) {
                providerJunkLabel = true
                trace.add(.providerJunkFolder, "provider", folder)
            }
        }

        // Step 2: sender and headers.
        if let from = m.from {
            let address = from.address.lowercased()
            fromAddress = address
            fromDomain = DomainHeuristics.domain(of: address)
            fromOrganisation = fromDomain.map(DomainHeuristics.organisationDomain)
            fromLocalPart = DomainHeuristics.localPart(of: address)
            isRoleAddress = Templates.roleLocalParts.contains(fromLocalPart)
            if isRoleAddress { trace.add(.roleAddress, "From", fromLocalPart) }
            if context.knownCorrespondents.contains(address) {
                knownCorrespondent = true
                trace.add(.knownCorrespondent, "From", address)
            }
        }

        if let listID = m.value("List-ID") {
            hasListSignals = true
            listIdentity = Signals.angleContent(listID)
            trace.add(.listID, "List-ID", listID)
        }
        if let unsubscribe = m.value("List-Unsubscribe") {
            hasListSignals = true
            trace.add(.listUnsubscribe, "List-Unsubscribe", unsubscribe)
        }
        if let post = m.value("List-Unsubscribe-Post") {
            hasListSignals = true
            oneClickUnsubscribe = true
            trace.add(.listUnsubscribePost, "List-Unsubscribe-Post", post)
        }
        if let post = m.value("List-Post") {
            listPost = post
            // RFC 2369: "NO" marks an announcement list that takes no posts.
            acceptsPosts = m.value("List-ID") != nil && post.trimmingCharacters(in: .whitespaces).uppercased() != "NO"
        }
        if let precedence = m.value("Precedence")?.lowercased(), ["bulk", "list", "junk"].contains(precedence) {
            hasListSignals = true
            trace.add(.bulkPrecedence, "Precedence", precedence)
        }
        if let auto = m.value("Auto-Submitted")?.lowercased(), auto != "no" {
            autoSubmitted = true
            trace.add(.autoSubmitted, "Auto-Submitted", auto)
        }
        if m.value("In-Reply-To") != nil || m.value("References") != nil {
            isReply = true
            trace.add(.threadReply, "In-Reply-To", m.value("In-Reply-To") ?? m.value("References") ?? "")
        }

        for result in m.values("Authentication-Results") {
            let authservID = result.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            guard context.trustedAuthServIDs.contains(authservID) else {
                trace.add(.authUntrustedIgnored, "Authentication-Results", authservID)
                continue
            }
            let lower = result.lowercased()
            let dmarc = Signals.method("dmarc", in: lower)
            let spf = Signals.method("spf", in: lower)
            let dkim = Signals.method("dkim", in: lower)
            if dmarc == "fail" || (["fail", "softfail"].contains(spf ?? "") && ["fail", "none"].contains(dkim ?? "")) {
                authFailed = true
                trace.add(.authTrustedFail, "Authentication-Results", "dmarc=\(dmarc ?? "-") spf=\(spf ?? "-") dkim=\(dkim ?? "-")")
            } else if dmarc == "pass" {
                trace.add(.authTrustedPass, "Authentication-Results", "dmarc=pass")
            }
        }

        if let organisation = fromOrganisation {
            for reply in m.replyTo {
                guard let domain = DomainHeuristics.domain(of: reply.address) else { continue }
                if DomainHeuristics.organisationDomain(domain) != organisation {
                    replyToMismatch = true
                    trace.add(.replyToMismatch, "Reply-To", domain)
                }
            }
            if let name = m.from?.name?.lowercased() {
                if let spoof = Signals.displayNameSpoof(name: name, organisation: organisation, trusted: context.trustedSenderDomains) {
                    displayNameSpoof = true
                    trace.add(.displayNameSpoof, "From", spoof)
                }
            }
            if let target = DomainHeuristics.lookalikeTarget(of: organisation, trusted: context.trustedSenderDomains) {
                lookalikeSender = target
                trace.add(.lookalikeSender, "From", "\(organisation) imitates \(target)")
            }
        }

        // Body, links and attachments.
        let html = m.htmlBody ?? ""
        let plain = m.textBody.isEmpty ? Signals.stripTags(html) : m.textBody
        bodyIsEmpty = plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let subject = m.subject.lowercased()
        let body = plain.lowercased()
        let subjectText = TemplateText(subject)
        let bodyText = TemplateText(body)

        let claimsTemplate = Templates.firstMatch(Templates.securityAlert, in: subjectText) != nil
            || Templates.firstMatch(Templates.transactionAction + Templates.transactionDue, in: subjectText) != nil
        for link in Signals.anchors(in: html) {
            guard let hrefHost = Signals.host(in: link.href) else { continue }
            guard let shownHost = Signals.host(in: Signals.stripTags(link.text)) else { continue }
            let shownOrganisation = DomainHeuristics.organisationDomain(shownHost)
            guard shownOrganisation != DomainHeuristics.organisationDomain(hrefHost) else { continue }
            // Campaign mail sends links through its mailing service's click tracker. That is
            // tracking, not deception, when the text shows the sender's own organisation, the
            // message is bulk mail, and it makes no claim about an account or a payment.
            if hasListSignals && !claimsTemplate && shownOrganisation == fromOrganisation && !displayNameSpoof {
                trace.add(.trackedLink, "link", "shows \(shownHost), counted through \(hrefHost)")
                continue
            }
            linkTextMismatch = true
            trace.add(.linkTextMismatch, "link", "shows \(shownHost), goes to \(hrefHost)")
        }
        for host in Signals.hosts(in: plain + "\n" + html) {
            let organisation = DomainHeuristics.organisationDomain(host)
            if let target = DomainHeuristics.lookalikeTarget(of: organisation, trusted: context.trustedSenderDomains) {
                lookalikeLink = target
                trace.add(.lookalikeLink, "link", "\(host) imitates \(target)")
                break
            }
        }
        for name in m.attachmentFilenames where Signals.isDangerous(filename: name) {
            dangerousAttachment = true
            trace.add(.dangerousAttachment, "attachment", name)
        }
        spamPhraseCount = Templates.spamPhrases.filter { subjectText.contains($0) || bodyText.contains($0) }.count
        if spamPhraseCount >= 2 { trace.add(.spamPhrases, "body", "\(spamPhraseCount) junk phrases") }
        structureFlags = m.structureFlags
        for flag in m.structureFlags.sorted(by: { $0.rawValue < $1.rawValue }) {
            trace.add(.hostileStructure, "structure", flag.rawValue)
        }

        // Step 4: templates.
        personalSender = fromAddress != nil && !isRoleAddress && !hasListSignals && !autoSubmitted
        var security: Template?
        if let term = Templates.firstMatch(Templates.securityCode, in: subjectText) ?? Templates.firstMatch(Templates.securityCode, in: bodyText),
           Signals.containsCode(plain) {
            security = Template(reason: .securityCode, field: "subject+body", term: term)
        } else if let term = Templates.firstMatch(Templates.securityAlert, in: subjectText) {
            security = Template(reason: .securityAlert, field: "subject", term: term)
        }
        securityClaim = security != nil
        // Account mail comes from a function (no-reply, security@), never from a person's own
        // address; a person writing about a password is having a conversation.
        if !personalSender { securityTemplate = security }
        deliveryTerm = Templates.firstMatch(Templates.delivery, in: subjectText)
        if let term = Templates.firstMatch(Templates.transactionAction, in: subjectText) {
            transactionTerm = term
            transactionKind = .action
        } else if let term = Templates.firstMatch(Templates.transactionDue, in: subjectText) {
            transactionTerm = term
            transactionKind = .due
        } else {
            transactionTerm = Templates.firstMatch(Templates.transaction, in: subjectText)
            transactionKind = .record
        }
        hasOrderReference = Signals.containsOrderReference(plain)
        hasMoneyAmount = Signals.containsMoney(body)
        codeHost = Signals.repositoryTag(in: m.subject) || m.headers.contains { Signals.isReasonHeader($0.name) }
        notificationSender = Templates.notificationLocalParts.contains(fromLocalPart)
        let reason = m.headers.first { Signals.isReasonHeader($0.name) }?.value.lowercased() ?? ""
        reviewRequested = ["review_requested", "mention", "assign"].contains { reason.contains($0) }
            || subject.contains("review requested") || subject.contains("mentioned you")
        promotionTerm = Templates.firstMatch(Templates.promotion, in: subjectText) ?? Signals.percentage(in: subject)
        newsletterTerm = Templates.firstMatch(Templates.newsletter, in: subjectText)
    }

    // MARK: Helpers

    static func angleContent(_ value: String) -> String {
        if let open = value.lastIndex(of: "<"), let close = value[open...].firstIndex(of: ">") {
            return value[value.index(after: open)..<close].lowercased()
        }
        return value.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func method(_ name: String, in result: String) -> String? {
        guard let range = result.range(of: #"(^|[\s;])"# + name + #"=([a-z]+)"#, options: .regularExpression) else { return nil }
        return result[range].split(separator: "=").last.map(String.init)
    }

    /// A display name that names another address, domain, or a trusted organisation the sender is not.
    static func displayNameSpoof(name: String, organisation: String, trusted: Set<String>) -> String? {
        for host in hosts(in: name, requireScheme: false) where DomainHeuristics.organisationDomain(host) != organisation {
            return "display name shows \(host)"
        }
        let words = Set(name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        for target in trusted where target != organisation {
            let label = DomainHeuristics.organisationLabel(target)
            if words.contains(label) && DomainHeuristics.organisationLabel(organisation) != label {
                return "display name claims \(label)"
            }
        }
        return nil
    }

    static func isDangerous(filename: String) -> Bool {
        let parts = filename.lowercased().split(separator: ".").map(String.init)
        guard parts.count >= 2, let ext = parts.last else { return false }
        return Templates.dangerousExtensions.contains(ext)
    }

    /// The provider's junk folder, by name: the last path component, so `[Gmail]/Spam` counts.
    static func isJunkFolder(_ folder: String) -> Bool {
        let last = folder.split(whereSeparator: { $0 == "/" || $0 == "." }).last.map { $0.lowercased() } ?? folder.lowercased()
        return Templates.junkLabels.contains(last)
    }

    static func isReasonHeader(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix("x-") && n.hasSuffix("-reason")
    }

    private static let repositoryPattern = try! NSRegularExpression(pattern: #"\[[\w.-]+/[\w.-]+\]"#)
    static func repositoryTag(in subject: String) -> Bool {
        repositoryPattern.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
    }

    private static let codePattern = try! NSRegularExpression(pattern: #"(?<!\d)(?<!\d[.,:/-])\d{4,8}(?!\d)(?![.,:/-]\d)"#)
    static func containsCode(_ text: String) -> Bool {
        codePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let moneyPattern = try! NSRegularExpression(
        pattern: #"((eur|usd|gbp|jpy|€|\$|£|¥)\s?\d)|(\d[\d.,]*\s?(eur|usd|€|円))"#, options: [.caseInsensitive])
    static func containsMoney(_ text: String) -> Bool {
        moneyPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let orderReferencePattern = try! NSRegularExpression(
        pattern: #"(order|bestelling|bestellung|bestellnummer|ordernummer|注文番号|παραγγελία)\s*(#|no\.?|number|nr\.?|nummer)?\s*[:#]?\s*[a-z]{0,4}-?\d{3,}"#,
        options: [.caseInsensitive])
    /// An order number in the body ("Order #12345", "Bestellnummer: 2026-77812").
    static func containsOrderReference(_ text: String) -> Bool {
        orderReferencePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let percentPattern = try! NSRegularExpression(pattern: #"-?\d{1,2}\s?%"#)
    static func percentage(in subject: String) -> String? {
        guard let match = percentPattern.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)),
              let range = Range(match.range, in: subject) else { return nil }
        return String(subject[range])
    }

    private static let anchorPattern = try! NSRegularExpression(
        pattern: #"<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    static func anchors(in html: String) -> [(href: String, text: String)] {
        let ns = html as NSString
        return anchorPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)))
        }
    }

    private static let schemeHostPattern = try! NSRegularExpression(pattern: #"https?://([a-z0-9.-]+\.[a-z]{2,})"#, options: [.caseInsensitive])
    private static let bareHostPattern = try! NSRegularExpression(
        pattern: #"(?:https?://)?((?:[a-z0-9-]+\.)+(?:com|org|net|nl|de|jp|gr|io|dev))\b"#, options: [.caseInsensitive])

    static func hosts(in text: String, requireScheme: Bool = true) -> [String] {
        let ns = text as NSString
        let pattern = requireScheme ? schemeHostPattern : bareHostPattern
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).lowercased()
        }
    }

    static func host(in text: String) -> String? {
        hosts(in: text.trimmingCharacters(in: .whitespacesAndNewlines), requireScheme: false).first
    }

    private static let tagPattern = try! NSRegularExpression(pattern: #"<[^>]+>"#)
    static func stripTags(_ html: String) -> String {
        tagPattern.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length), withTemplate: " ")
    }
}
