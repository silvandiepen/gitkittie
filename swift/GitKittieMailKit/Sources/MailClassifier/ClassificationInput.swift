import Foundation
import MailCore

/// The parts of a message the classifier reads: a small header and body view, independent of
/// any MIME library. Whatever parses the message (provisionally `ProvisionalMessageReader` in
/// MailTestSupport; the GKM-002 library later) fills this in.
public struct ClassificationInput: Sendable {
    public struct Header: Sendable, Equatable {
        public var name: String
        public var value: String
        public init(name: String, value: String) { self.name = name; self.value = value }
    }

    public var messageID: String?
    public var from: MailAddress?
    public var replyTo: [MailAddress]
    public var subject: String
    /// All top-level headers, unfolded and RFC 2047 decoded. Headers can be forged: the
    /// classifier treats them as signals, never as proof.
    public var headers: [Header]
    public var textBody: String
    public var htmlBody: String?
    public var attachmentFilenames: [String]
    /// What the parser had to refuse or rewrite.
    public var structureFlags: Set<StructureFlag>
    /// What the provider already decided (step 1). Nil when the provider said nothing.
    public var provider: ProviderSignals?

    public init(messageID: String? = nil, from: MailAddress? = nil, replyTo: [MailAddress] = [], subject: String = "",
                headers: [Header] = [], textBody: String = "", htmlBody: String? = nil,
                attachmentFilenames: [String] = [], structureFlags: Set<StructureFlag> = [], provider: ProviderSignals? = nil) {
        self.messageID = messageID
        self.from = from
        self.replyTo = replyTo
        self.subject = subject
        self.headers = headers
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachmentFilenames = attachmentFilenames
        self.structureFlags = structureFlags
        self.provider = provider
    }

    public func values(_ name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    public func value(_ name: String) -> String? { values(name).first }
}

/// Hostile or broken structure the parser reported.
public enum StructureFlag: String, Codable, Sendable {
    case nestingLimitExceeded = "nesting-limit-exceeded"
    case unsafeAttachmentFilename = "unsafe-attachment-filename"
}

/// The provider's spam verdict and labels/folders (Classification.md, step 1).
public struct ProviderSignals: Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable { case spam, phishing, notSpam }
    public var verdict: Verdict?
    public var labels: [String]
    public init(verdict: Verdict? = nil, labels: [String] = []) { self.verdict = verdict; self.labels = labels }
}

/// What the classifier knows about the mailbox and what the user decided (step 3).
public struct ClassificationContext: Sendable {
    public var accountAddresses: Set<String>
    /// Only Authentication-Results from these `authserv-id`s count; anything else is ignored.
    /// The account's provider must strip same-named headers arriving from outside.
    public var trustedAuthServIDs: Set<String>
    /// Addresses the user has written to.
    public var knownCorrespondents: Set<String>
    /// Organisation domains the user has an established, authenticated relationship with;
    /// lookalikes of these are treated as impersonation.
    public var trustedSenderDomains: Set<String>
    public var overrides: [MessageOverride]
    public var rules: [ScopedRule]

    public init(accountAddresses: Set<String> = [], trustedAuthServIDs: Set<String> = [], knownCorrespondents: Set<String> = [],
                trustedSenderDomains: Set<String> = [], overrides: [MessageOverride] = [], rules: [ScopedRule] = []) {
        self.accountAddresses = Set(accountAddresses.map { $0.lowercased() })
        self.trustedAuthServIDs = Set(trustedAuthServIDs.map { $0.lowercased() })
        self.knownCorrespondents = Set(knownCorrespondents.map { $0.lowercased() })
        self.trustedSenderDomains = Set(trustedSenderDomains.map { $0.lowercased() })
        self.overrides = overrides
        self.rules = rules
    }
}

/// A user's correction for one message. It wins over everything, including risk: it is an
/// explicit decision about this message only and never generalises (Classification.md, step 6).
public struct MessageOverride: Sendable, Equatable, Codable {
    public var messageID: String
    public var purpose: MailPurpose?
    public var risk: MailRisk?
    public var urgency: MailUrgency?
    public init(messageID: String, purpose: MailPurpose? = nil, risk: MailRisk? = nil, urgency: MailUrgency? = nil) {
        self.messageID = messageID
        self.purpose = purpose
        self.risk = risk
        self.urgency = urgency
    }
}

/// A user rule over many messages. Rules set purpose (and optionally urgency); they never lower
/// risk, so a rule for a sender cannot hide a spoof of that sender.
///
/// Precedence: the most specific scope wins (list > sender address > sender domain); within a
/// scope, the lowest `order`, then the rule id. Disabled rules are ignored.
public struct ScopedRule: Sendable, Equatable, Codable {
    public enum Scope: Sendable, Equatable, Codable {
        /// A List-ID value, without angle brackets, compared case-insensitively.
        case listID(String)
        /// The From address (never the display name).
        case senderAddress(String)
        /// The From domain or any subdomain of it.
        case senderDomain(String)

        var specificity: Int {
            switch self {
            case .listID: 3
            case .senderAddress: 2
            case .senderDomain: 1
            }
        }
    }

    public var id: String
    public var scope: Scope
    public var purpose: MailPurpose
    public var urgency: MailUrgency?
    public var order: Int
    public var isEnabled: Bool

    public init(id: String, scope: Scope, purpose: MailPurpose, urgency: MailUrgency? = nil, order: Int = 0, isEnabled: Bool = true) {
        self.id = id
        self.scope = scope
        self.purpose = purpose
        self.urgency = urgency
        self.order = order
        self.isEnabled = isEnabled
    }
}
