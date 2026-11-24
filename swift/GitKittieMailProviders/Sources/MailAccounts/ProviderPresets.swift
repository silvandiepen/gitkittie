import Foundation
import MailCore

/// Server settings for well-known providers, so most people only type an address and an app
/// password (GKM-010). iCloud and Gmail follow the provider pages cited in ProviderAccess.md;
/// Fastmail and Yahoo are their long-standing published settings, not yet tried against a live
/// account. A provider can change them, which is why every field stays editable.
public struct ProviderPreset: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var kind: MailAccountKind
    public var domains: [String]
    public var imap: (host: String, port: Int, security: MailServerSecurity)
    public var smtp: (host: String, port: Int, security: MailServerSecurity)
    /// Where the provider explains app passwords, for the setup sheet's link.
    public var appPasswordHelp: URL?
    /// One sentence on what the person needs, shown under the password field.
    public var passwordNote: String

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// The settings for an address at this provider: the full address as the user name on
    /// both servers.
    public func connection(for address: String) -> MailConnectionSettings {
        MailConnectionSettings(
            kind: kind,
            imap: MailServerSettings(host: imap.host, port: imap.port, security: imap.security, username: address),
            smtp: MailServerSettings(host: smtp.host, port: smtp.port, security: smtp.security, username: address))
    }
}

public enum ProviderPresets {
    /// iCloud Mail (https://support.apple.com/en-us/102525, read 2026-11-24): IMAP 993 over TLS,
    /// SMTP 587 with STARTTLS, an app-specific password (https://support.apple.com/en-us/102654).
    public static let iCloud = ProviderPreset(
        id: "icloud", name: "iCloud", kind: .iCloud, domains: ["icloud.com", "me.com", "mac.com"],
        imap: ("imap.mail.me.com", 993, .implicitTLS), smtp: ("smtp.mail.me.com", 587, .startTLS),
        appPasswordHelp: URL(string: "https://support.apple.com/en-us/102654"),
        passwordNote: "Use an app-specific password, not your Apple Account password. You make one at account.apple.com, under Sign-In and Security.")

    /// Gmail with an app password (MAIL-016, pending Sil; https://support.google.com/mail/answer/7126229
    /// and https://support.google.com/accounts/answer/185833, read 2026-11-24).
    public static let gmail = ProviderPreset(
        id: "gmail", name: "Gmail", kind: .gmail, domains: ["gmail.com", "googlemail.com"],
        imap: ("imap.gmail.com", 993, .implicitTLS), smtp: ("smtp.gmail.com", 465, .implicitTLS),
        appPasswordHelp: URL(string: "https://support.google.com/accounts/answer/185833"),
        passwordNote: "Use an app password. Gmail offers them once 2-Step Verification is on; accounts that sign in only with a security key can't make one.")

    /// Fastmail: IMAP 993 and SMTP 465, both TLS, with an app password.
    public static let fastmail = ProviderPreset(
        id: "fastmail", name: "Fastmail", kind: .imap, domains: ["fastmail.com", "fastmail.fm"],
        imap: ("imap.fastmail.com", 993, .implicitTLS), smtp: ("smtp.fastmail.com", 465, .implicitTLS),
        appPasswordHelp: nil,
        passwordNote: "Use an app password from Fastmail's Privacy & Security settings.")

    /// Yahoo Mail: IMAP 993 and SMTP 465, both TLS, with an app password.
    public static let yahoo = ProviderPreset(
        id: "yahoo", name: "Yahoo", kind: .imap, domains: ["yahoo.com", "ymail.com", "rocketmail.com"],
        imap: ("imap.mail.yahoo.com", 993, .implicitTLS), smtp: ("smtp.mail.yahoo.com", 465, .implicitTLS),
        appPasswordHelp: nil,
        passwordNote: "Use an app password from your Yahoo account's security settings.")

    /// The presets the Other IMAP form offers, after "Custom".
    public static let all: [ProviderPreset] = [gmail, fastmail, yahoo, iCloud]

    /// Domains whose provider no longer accepts passwords over IMAP, so a password form would
    /// only ever fail. Outlook.com needs OAuth since 2024-09-16 (ProviderAccess.md); it comes
    /// with GKM-030.
    public static let oauthOnlyDomains: Set<String> = ["outlook.com", "hotmail.com", "live.com", "msn.com"]

    /// The preset for an address's domain, if it is a provider we know.
    public static func preset(for address: String) -> ProviderPreset? {
        guard let domain = domain(of: address) else { return nil }
        return ([iCloud] + all).first { $0.domains.contains(domain) }
    }

    /// The lowercased domain of an address, or nil when it is not an address.
    public static func domain(of address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return nil }
        return parts[1].lowercased()
    }

    /// A guess for an unknown domain: `imap.<domain>:993` and `smtp.<domain>:587`. Only a
    /// starting point for the form; verification decides.
    public static func guess(for address: String) -> MailConnectionSettings? {
        guard let domain = domain(of: address) else { return nil }
        let user = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return MailConnectionSettings(
            kind: .imap,
            imap: MailServerSettings(host: "imap.\(domain)", port: 993, security: .implicitTLS, username: user),
            smtp: MailServerSettings(host: "smtp.\(domain)", port: 587, security: .startTLS, username: user))
    }

    /// iCloud's IMAP user name is usually the part before the @; Apple says to try the full
    /// address when that fails (https://support.apple.com/en-us/102525). Verification tries
    /// these in order and keeps the one the server accepts.
    public static func iCloudIMAPUsernames(for address: String) -> [String] {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@") else { return [trimmed] }
        return [String(trimmed[..<at]), trimmed]
    }
}
