import Foundation
import MailAccounts
import MailCore

/// What the Add Account sheet collects, before it is verified and saved (GKM-010). UI-free:
/// the sheet binds to it, the model turns it into settings and checks them.
struct AccountDraft: Equatable {
    enum Provider: String, CaseIterable, Identifiable {
        case iCloud
        case other
        var id: String { rawValue }
    }

    var provider: Provider = .iCloud
    var address = ""
    var name = ""
    /// Held only until the account is saved; then it is in the Keychain and this draft is gone.
    var password = ""

    // Other IMAP only. Filled from a preset or a guess when the address changes, editable.
    var presetID: String?
    var imapHost = ""
    var imapPort = 993
    var smtpHost = ""
    var smtpPort = 587
    var smtpSecurity: MailServerSecurity = .startTLS
    /// Empty means the address.
    var username = ""

    var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The preset that matches the address, for the note under the password field.
    var preset: ProviderPreset? {
        switch provider {
        case .iCloud: ProviderPresets.iCloud
        case .other: presetID.flatMap { id in ProviderPresets.all.first { $0.id == id } }
        }
    }

    /// Fills the server fields from the address: a known provider's preset, otherwise a
    /// guess (`imap.<domain>`). Only touches what the person has not changed from the
    /// previous suggestion, so a typed host survives typing the address.
    mutating func suggestServers(previous: AccountDraft? = nil) {
        guard provider == .other else { return }
        let suggestion: MailConnectionSettings?
        if let preset = ProviderPresets.preset(for: trimmedAddress), preset.kind != .iCloud {
            presetID = preset.id
            suggestion = preset.connection(for: trimmedAddress)
        } else {
            presetID = nil
            suggestion = ProviderPresets.guess(for: trimmedAddress)
        }
        guard let suggestion else { return }
        let untouched = previous.map { $0.imapHost == imapHost && $0.smtpHost == smtpHost } ?? true
        let empty = imapHost.isEmpty && smtpHost.isEmpty
        guard untouched || empty else { return }
        imapHost = suggestion.imap.host
        imapPort = suggestion.imap.port
        smtpHost = suggestion.smtp.host
        smtpPort = suggestion.smtp.port
        smtpSecurity = suggestion.smtp.security
    }

    /// The settings to verify, or what is missing.
    func connection() throws(AccountSetupError) -> MailConnectionSettings {
        let address = trimmedAddress
        guard !address.isEmpty else { throw .missingField("email address") }
        guard let domain = ProviderPresets.domain(of: address) else { throw .invalidAddress }
        guard !ProviderPresets.oauthOnlyDomains.contains(domain) else { throw .oauthOnly(domain: domain) }
        guard !password.isEmpty else { throw .missingField(provider == .iCloud ? "app-specific password" : "password") }
        switch provider {
        case .iCloud:
            return ProviderPresets.iCloud.connection(for: address)
        case .other:
            let imap = imapHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let smtp = smtpHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !imap.isEmpty else { throw .missingField("incoming mail server") }
            guard !smtp.isEmpty else { throw .missingField("outgoing mail server") }
            guard (1...65535).contains(imapPort), (1...65535).contains(smtpPort) else { throw .missingField("port (1 to 65535)") }
            let user = username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? address : username.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind: MailAccountKind = presetID == ProviderPresets.gmail.id ? .gmail : .imap
            return MailConnectionSettings(
                kind: kind,
                imap: MailServerSettings(host: imap, port: imapPort, security: .implicitTLS, username: user),
                smtp: MailServerSettings(host: smtp, port: smtpPort, security: smtpSecurity, username: user))
        }
    }

    /// What the sidebar calls the account: the name given, or the provider's, or the address.
    var displayName: String {
        let given = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !given.isEmpty { return given }
        if provider == .iCloud { return "iCloud" }
        if let preset { return preset.name }
        return trimmedAddress
    }
}
