import MailCore
import MailStore
import SwiftUI

/// What the menu bar asks the mail window for: the sheets the sidebar opens, the search field
/// and the filters. One object, so every sidebar and toolbar action also has a menu item and
/// works from the keyboard alone (GKM-061).
@MainActor
@Observable
final class MailWindowRequests {
    var accountSheet: AccountSheet?
    var spaceSheet: SpaceSheet?
    /// A space waiting for "Delete Space?" to be confirmed.
    var deletingSpace: MailSpace?
    var showsFilters = false
    /// Counts Edit ▸ Find ▸ Search Mail; the list focuses its search field on each change.
    var searchRequests = 0
    /// File ▸ Restore Encrypted Archive… (GKM-032).
    var restoresArchive = false
}

/// The Mailbox menu: accounts, spaces, sync, notifications and the mail folder, for whatever
/// is selected in the sidebar. The same items as the sidebar's footer and right-click menus;
/// the account's settings, mailboxes and notifications open in Settings (GKM-066).
struct MailboxCommands: Commands {
    let model: AppModel
    let requests: MailWindowRequests
    let settings: SettingsNavigation
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            // Items with a shortcut have no .disabled: SwiftUI would keep the state from launch
            // until the menu is opened. They check the model as they run (GITKITTIE-098).
            Button("Search Mail") {
                guard model.canRun(.searchMail) else { return }
                requests.searchRequests += 1
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
        }
        CommandMenu("Mailbox") {
            // No shortcut, so these may be disabled while the mail folder is read-only (GKM-104).
            Button("Add Account…") { requests.accountSheet = .add }
                .disabled(!model.canWrite)
            Button("New Space…") { requests.spaceSheet = .create }
                .disabled(!model.canWrite)
            Divider()
            // As in Apple Mail's Get All New Mail.
            Button("Sync Now") {
                guard model.canRun(.syncNow) else { return }
                Task { await model.sync.syncNow() }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            AccountMenuItems(model: model, requests: requests, settings: settings, account: selectedAccount)
            Divider()
            SpaceMenuItems(model: model, requests: requests, space: selectedSpace)
            Divider()
            Button("Notifications…") { settings.show(.notifications, with: openSettings) }
            Button(requests.showsFilters ? "Hide Search Filters" : "Show Search Filters") { requests.showsFilters.toggle() }
            Divider()
            if let folder = model.mailFolder {
                Button("Show Mail Folder in Finder") { Platform.reveal(folder) }
            }
            Button("Use Another Mail Folder…") { Task { await MailFolderChoice.chooseAnother(model) } }
            if !model.usesDefaultMailFolder {
                Button("Use the Default Mail Folder") { Task { await model.useMailFolder(nil) } }
            }
        }
    }

    /// The account of the selected account or folder row.
    private var selectedAccount: MailAccount? {
        switch model.selection {
        case .account(let id), .folder(let id, _): model.accounts.first { $0.id == id }
        default: nil
        }
    }

    private var selectedSpace: MailSpace? {
        if case .space(let id) = model.selection { return model.spaces.space(id) }
        return nil
    }
}

/// The selected account's actions; the account row's right-click menu shows the same.
struct AccountMenuItems: View {
    let model: AppModel
    let requests: MailWindowRequests
    let settings: SettingsNavigation
    let account: MailAccount?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let account {
            if model.needsPassword(account.id) {
                Button("Sign In Again…") { requests.accountSheet = .signIn(account) }
            }
            Button("Account Settings…") { settings.show(.accounts, account: account.id, pane: .information, with: openSettings) }
            if account.connection != nil {
                Button("Mailboxes…") { settings.show(.accounts, account: account.id, pane: .mailboxes, with: openSettings) }
            }
            Button("Export Account…") { Task { await Platform.export(.account(account.id), what: account.displayName, model: model) } }
            if (model.sync.replay[account.id]?.status.failed ?? 0) > 0 {
                Button("Try Failed Changes Again") { Task { await model.actions.retryFailed(account: account.id) } }
                Button("Discard Failed Changes") { Task { await model.actions.discardFailed(account: account.id) } }
            }
            Button("Remove Account…") { requests.accountSheet = .remove(account) }
        } else {
            // Named, so the menu says what to select to use them.
            Button("Account Settings…") {}.disabled(true)
            Button("Remove Account…") {}.disabled(true)
        }
    }
}

/// The selected space's actions; the space row's right-click menu shows the same.
struct SpaceMenuItems: View {
    let model: AppModel
    let requests: MailWindowRequests
    let space: MailSpace?

    var body: some View {
        if let space {
            Button("Edit Space…") { requests.spaceSheet = .edit(space) }
            Button("Export Space…") { Task { await Platform.export(.space(space.id), what: space.name, model: model) } }
            // Pin for offline (GKM-036): every message in the space downloaded whole and kept.
            Button("Keep Space Offline") { Task { await model.pin(.space(space.id)) } }
            Button("Don’t Keep Space Offline") { Task { await model.unpin(.space(space.id)) } }
            Button("Delete Space…") { requests.deletingSpace = space }
        } else {
            Button("Edit Space…") {}.disabled(true)
            Button("Delete Space…") {}.disabled(true)
        }
    }
}

enum MailFolderChoice {
    /// Shows another folder's mail. The current folder stays as it is.
    @MainActor
    static func chooseAnother(_ model: AppModel) async {
        guard let url = await Platform.chooseFolder(
            title: "Use Another Mail Folder", prompt: "Use Folder",
            message: "GitKittie Mail shows the accounts and mail in the folder you choose. The current folder stays as it is.") else { return }
        await model.useMailFolder(url)
    }
}

extension View {
    /// The sheets and the space deletion the sidebar and the Mailbox menu open, on the mail
    /// window, so they open even when the sidebar is hidden.
    func mailWindowSheets(_ requests: MailWindowRequests, model: AppModel) -> some View {
        modifier(MailWindowSheets(requests: requests, model: model))
    }
}

private struct MailWindowSheets: ViewModifier {
    @Bindable var requests: MailWindowRequests
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $requests.accountSheet) { $0.view }
            .sheet(item: $requests.spaceSheet) { sheet in
                switch sheet {
                case .create: SpaceEditorSheet(space: nil)
                case .edit(let space): SpaceEditorSheet(space: space)
                }
            }
            .confirmationDialog("Delete “\(requests.deletingSpace?.name ?? "")”?", isPresented: Binding(
                get: { requests.deletingSpace != nil }, set: { if !$0 { requests.deletingSpace = nil } }
            ), presenting: requests.deletingSpace) { space in
                Button("Delete Space", role: .destructive) {
                    Task {
                        if model.selection == .space(space.id) { await model.select(.allMail) }
                        await model.spaces.delete(space.id)
                    }
                }
            } message: { _ in
                Text("Only the space goes. Its messages stay in your Mail folder and at your mail provider.")
            }
            // The encrypted archive's recovery key and restore (GKM-032).
            .encryptedArchiveChrome(model, restoring: $requests.restoresArchive)
    }
}
