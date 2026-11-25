import MailCore
import Observation
import SwiftUI

/// The tabs of Mail ▸ Settings… (GKM-066).
enum SettingsTab: String, Hashable, CaseIterable {
    case general, accounts, notifications, storage
}

/// Which tab the Settings window shows, and which account: the sidebar's buttons and menus set
/// it before they open the window, so each opens on what it is about.
@MainActor
@Observable
final class SettingsNavigation {
    var tab: SettingsTab = .general
    var account: MailAccountID?
    /// The part of the account's settings to show.
    var accountPane: AccountSettingsPane = .information
    /// Settings asks to add an account: the sheet opens in the Settings window.
    var addsAccount = false
}

/// The parts of an account's settings.
enum AccountSettingsPane: String, Hashable, CaseIterable {
    case information, mailboxes, servers

    var title: String {
        switch self {
        case .information: "Account Information"
        case .mailboxes: "Mailboxes"
        case .servers: "Server Settings"
        }
    }
}

extension SettingsNavigation {
    /// Opens Settings on a tab (and an account, and a part of its settings), from the main
    /// window's buttons and menus: `settings.show(.accounts, account: id, with: openSettings)`.
    func show(_ tab: SettingsTab, account: MailAccountID? = nil, pane: AccountSettingsPane? = nil, with openSettings: OpenSettingsAction) {
        self.tab = tab
        if let account { self.account = account }
        if let pane { accountPane = pane }
        openSettings()
    }
}
