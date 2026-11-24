import Foundation
import MailCore

// Spaces (GKM-022; Features.md, Spaces; MAIL-042..044): virtual collections by project, person,
// company or area, across accounts. A space is metadata in the mail folder, one file per space
// at `Mail/spaces/<space-id>.json`. It names messages by their local id and never copies them,
// so a message in three spaces is still one `.eml` on disk; deleting a space deletes that file
// and nothing else, here or at the provider.
//
// The file format is stable and versioned (`format`), because private CloudKit sync of spaces
// (GKM-026) will map it record for record. Architecture.md, "Spaces", documents every key.

/// A space's id: a lowercase UUID, so it is always a safe file name.
public struct MailSpaceID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init() { self.rawValue = UUID().uuidString.lowercased() }

    /// Only a well-formed UUID is accepted: a name read from the folder never becomes a path.
    public init?(_ rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        self.rawValue = uuid.uuidString.lowercased()
    }

    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = MailSpaceID(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a space id: \(raw)"))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A space: its name and look, the rules that fill it, and its messages.
public struct MailSpace: Codable, Hashable, Sendable, Identifiable {
    /// The version of this file's format. A file from a newer app is left alone, never rewritten.
    public static let formatVersion = 1

    public var format: Int
    public var id: MailSpaceID
    public var name: String
    /// An SF Symbol name; one of `SpaceAppearance.icons` from the picker, any other still shows.
    public var icon: String
    /// One of `SpaceAppearance.colors` (the names Tasks boards use).
    public var color: String
    /// Position in the sidebar, ascending; ties sort by name.
    public var order: Int
    public var created: Date
    public var modified: Date
    /// Each rule adds the messages it matches; a message matching any rule is added.
    public var rules: [SpaceRule]
    /// The messages in the space.
    public var members: [SpaceMember]
    /// Messages taken out by hand. A rule never adds them back; adding one by hand does.
    public var excluded: [SpaceMember]

    public init(id: MailSpaceID = MailSpaceID(), name: String, icon: String = SpaceAppearance.defaultIcon,
                color: String = SpaceAppearance.defaultColor, order: Int = 0, created: Date = Date(),
                rules: [SpaceRule] = [], members: [SpaceMember] = [], excluded: [SpaceMember] = []) {
        let now = Date(timeIntervalSince1970: created.timeIntervalSince1970.rounded(.down))
        self.format = Self.formatVersion
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.order = order
        self.created = now
        self.modified = now
        self.rules = rules
        self.members = members
        self.excluded = excluded
    }

    public var memberIDs: Set<MailMessageID> { Set(members.map(\.message)) }
    public var excludedIDs: Set<MailMessageID> { Set(excluded.map(\.message)) }
}

/// One rule: every condition it sets must hold (AND). Conditions left nil are not checked; a
/// rule with none matches nothing.
public struct SpaceRule: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// The sender's address, exactly (case-insensitive).
    public var sender: String?
    /// The sender's domain, or any subdomain of it: `example.com` matches `mail.example.com`.
    public var domain: String?
    /// The mailing list's List-Id identifier (`news.example.org`).
    public var list: String?
    /// Words that must all be in the subject (each matched as a word prefix).
    public var subjectWords: String?
    /// Only messages in this account.
    public var account: MailAccountID?

    public init(id: String = UUID().uuidString.lowercased(), sender: String? = nil, domain: String? = nil, list: String? = nil,
                subjectWords: String? = nil, account: MailAccountID? = nil) {
        self.id = id
        self.sender = sender
        self.domain = domain
        self.list = list
        self.subjectWords = subjectWords
        self.account = account
    }

    /// The rule with blank conditions removed and values in the form they are matched in.
    public var normalized: SpaceRule {
        func clean(_ value: String?, lower: Bool = true) -> String? {
            guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            if lower { value = value.lowercased() }
            return value
        }
        var rule = self
        rule.sender = clean(sender)
        rule.domain = clean(domain).map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 }
        rule.list = clean(list).flatMap { MIMEMessageParser.listIdentifier($0) }
        rule.subjectWords = clean(subjectWords, lower: false)
        return rule
    }

    /// True when the rule sets no message condition (an account alone is not enough: it would
    /// put a whole account in the space, which is what the account view is for).
    public var isEmpty: Bool {
        let rule = normalized
        return rule.sender == nil && rule.domain == nil && rule.list == nil && rule.subjectWords == nil
    }

    /// How the rule reads in the editor and the sidebar's help text.
    public var summary: String {
        let rule = normalized
        var parts: [String] = []
        if let sender = rule.sender { parts.append("from \(sender)") }
        if let domain = rule.domain { parts.append("from anyone at \(domain)") }
        if let list = rule.list { parts.append("on the list \(list)") }
        if let words = rule.subjectWords { parts.append("subject has “\(words)”") }
        if rule.account != nil { parts.append("in one account") }
        return parts.isEmpty ? "No conditions" : parts.joined(separator: ", ")
    }
}

/// A message in a space (or taken out of one). `message` is the key in this folder. The other
/// fields identify the same message where local ids differ (another device's own store, which
/// CloudKit sync must match by account, Message-ID and original hash; GKM-026).
public struct SpaceMember: Codable, Hashable, Sendable {
    public var message: MailMessageID
    public var account: MailAccountID
    public var messageId: String?
    /// SHA-256 of the original `.eml`.
    public var emlSha256: String
    public var added: Date
    /// `manual`, or `rule:<rule-id>` for a message a rule added.
    public var source: String

    public init(message: MailMessageID, account: MailAccountID, messageId: String?, emlSha256: String, added: Date, source: String) {
        self.message = message
        self.account = account
        self.messageId = messageId
        self.emlSha256 = emlSha256
        self.added = added
        self.source = source
    }

    public static let manual = "manual"
    public static func rule(_ id: String) -> String { "rule:\(id)" }
}

/// What a rule would add, before it is saved.
public struct SpaceRulePreview: Equatable, Sendable {
    /// Every message the rule matches.
    public var matchCount: Int
    /// Of those, how many are not in the space yet and not taken out by hand.
    public var newCount: Int
    /// The newest matches, for the person to check.
    public var samples: [MessageSummary]
}

/// The icons and colours a space can be given: the colour names Tasks boards use
/// (`BoardAppearance` in GitKittieKit), so a project looks the same in both apps.
public enum SpaceAppearance {
    public static let defaultIcon = "square.stack.3d.up.fill"
    public static let defaultColor = "blue"
    public static let colors = ["blue", "indigo", "purple", "pink", "red", "orange", "yellow", "green", "mint", "teal", "brown", "gray"]
    public static let icons = [
        "square.stack.3d.up.fill", "folder.fill", "tray.full.fill", "briefcase.fill", "building.2.fill", "person.2.fill",
        "person.crop.circle.fill", "house.fill", "doc.text.fill", "hammer.fill", "wrench.and.screwdriver.fill",
        "chevron.left.forwardslash.chevron.right", "paintbrush.fill", "photo.fill", "camera.fill", "film.fill", "music.note",
        "book.fill", "graduationcap.fill", "megaphone.fill", "envelope.fill", "cart.fill", "creditcard.fill", "banknote.fill",
        "chart.bar.fill", "globe", "airplane", "car.fill", "map.fill", "heart.fill", "star.fill", "leaf.fill", "pawprint.fill",
        "gamecontroller.fill", "sparkles", "bolt.fill",
    ]
}
