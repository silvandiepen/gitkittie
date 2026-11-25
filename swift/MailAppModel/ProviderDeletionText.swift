import Foundation
import MailAccounts
import MailCore
import MailStore

/// How the list and the reader say a message was deleted at the provider (GKM-011, MAIL-075):
/// "Deleted at iCloud · 25 Nov 2026 at 14:02". The local copy is kept; the line says where it
/// went and when this device noticed.
enum ProviderDeletionText {
    /// The provider's name as people know it: iCloud and Gmail by name, any other IMAP account
    /// by its sidebar name.
    static func providerName(of account: MailAccount?) -> String {
        guard let account else { return "the provider" }
        switch account.connection?.kind {
        case .iCloud: return "iCloud"
        case .gmail: return "Gmail"
        case .imap, nil: return account.displayName.isEmpty ? "the provider" : account.displayName
        }
    }

    /// The short line for a list row: "Deleted at iCloud".
    static func short(_ summary: MessageSummary, account: MailAccount?) -> String? {
        guard summary.deletedAtProvider != nil else { return nil }
        return "Deleted at \(providerName(of: account))"
    }

    /// The reader's line, with the time: "Deleted at iCloud · 25 Nov 2026 at 14:02".
    static func line(_ summary: MessageSummary, account: MailAccount?, timeZone: TimeZone = .current,
                     locale: Locale = .current) -> String? {
        guard let date = summary.deletedAtProvider else { return nil }
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = timeZone
        style.locale = locale
        return "Deleted at \(providerName(of: account)) · \(date.formatted(style))"
    }

    /// What the reader adds under the line, so the person knows what it means and what to do.
    static func explanation(removesHere: Bool) -> String {
        removesHere
            ? "This copy is removed from \(DeviceWords.this) on the next sync, unless it is pinned or in a space."
            : "It is kept in your mail folder on \(DeviceWords.this). Turn on “Remove mail deleted elsewhere” in the account’s settings to remove such mail here too."
    }
}

extension AppModel {
    /// The account a message belongs to, for the provider's name.
    func account(of summary: MessageSummary) -> MailAccount? {
        accounts.first { $0.id == summary.account }
    }
}
