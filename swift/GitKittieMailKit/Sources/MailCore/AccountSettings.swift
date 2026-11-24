import Foundation

// How an account reaches its provider (GKM-010). Recorded in `account.json` beside the mail, so
// another device can offer the same servers; the password never is: it lives in this device's
// Keychain only (ThreatModel.md §5).

/// Which kind of account this is. It decides the onboarding text and the defaults, never the
/// protocol: every kind connects over IMAP and SMTP (MAIL-014, MAIL-016).
public enum MailAccountKind: String, Codable, Sendable, Hashable, CaseIterable {
    case iCloud
    case gmail
    case imap
}

/// How the connection to a server is protected. Plain text is not offered to people: it exists
/// only in the provider layer, for a server on this machine (tests, a local bridge).
public enum MailServerSecurity: String, Codable, Sendable, Hashable, CaseIterable {
    /// TLS from the first byte: IMAP 993, SMTP 465.
    case implicitTLS
    /// A plain greeting, then STARTTLS before anything else: SMTP 587. Never continues without it.
    case startTLS
}

/// One server: where it is, how it is protected, and the user name to sign in with.
public struct MailServerSettings: Codable, Sendable, Hashable {
    public var host: String
    public var port: Int
    public var security: MailServerSecurity
    public var username: String

    public init(host: String, port: Int, security: MailServerSecurity, username: String) {
        self.host = host
        self.port = port
        self.security = security
        self.username = username
    }
}

/// The incoming (IMAP) and outgoing (SMTP) servers of an account.
public struct MailConnectionSettings: Codable, Sendable, Hashable {
    public var kind: MailAccountKind
    public var imap: MailServerSettings
    public var smtp: MailServerSettings

    public init(kind: MailAccountKind, imap: MailServerSettings, smtp: MailServerSettings) {
        self.kind = kind
        self.imap = imap
        self.smtp = smtp
    }
}

/// A message's state at the provider: read, answered, flagged, draft, and any keywords. The
/// provider is authoritative for it (Architecture.md, Storage and identity), so this is a
/// device-local copy, refreshed by sync; it never lives in the mail folder.
public struct MailMessageFlags: Codable, Sendable, Hashable {
    public var seen: Bool
    public var answered: Bool
    public var flagged: Bool
    public var draft: Bool
    /// Keywords such as `$Forwarded` or `$Junk`, sorted.
    public var keywords: [String]

    public init(seen: Bool = false, answered: Bool = false, flagged: Bool = false, draft: Bool = false, keywords: [String] = []) {
        self.seen = seen
        self.answered = answered
        self.flagged = flagged
        self.draft = draft
        self.keywords = keywords.sorted()
    }
}
