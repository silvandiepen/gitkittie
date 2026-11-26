import Foundation
import MailAccounts
import MailCore
import MailProvider
import MailStore
import MailSync

// An account's mailboxes in Settings (GKM-066, MAIL-093..096): which folders sync and show,
// their order, the special folders chosen by hand, and folders created, renamed and deleted at
// the provider. Shared by the Mac's Settings window and the iPhone and iPad Settings screen.
extension AppModel {
    /// An account's folders for the sidebar: those it shows, in its order. Before the first sync
    /// (or for an account that no longer syncs) the folders that hold stored mail.
    func sidebarFolders(of account: MailAccount) -> [SyncedFolder] {
        let settings = account.mailboxSettings
        return settings.ordered(allFolders(of: account), name: \.name).filter { settings.shows($0.name) }
    }

    /// Every folder of an account, in its sidebar order, for Settings.
    func settingsFolders(of account: MailAccount) -> [SyncedFolder] {
        account.mailboxSettings.ordered(allFolders(of: account), name: \.name)
    }

    private func allFolders(of account: MailAccount) -> [SyncedFolder] {
        if let synced = sync.folders[account.id], !synced.isEmpty { return synced }
        return (folders[account.id] ?? []).map { name in
            SyncedFolder(name: name, path: [name], role: name.caseInsensitiveCompare("INBOX") == .orderedSame ? "inbox" : nil)
        }
    }

    /// The folders that can be chosen for a special role: any but the inbox and the provider's
    /// All Mail and Starred (MAIL-094).
    func specialFolderCandidates(of account: MailAccount) -> [SyncedFolder] {
        settingsFolders(of: account).filter { !MailboxSettings.fixedRoles.contains($0.detectedRole ?? "") }
    }

    /// The folder the provider marked for a role, if any.
    func detectedFolder(for role: String, of account: MailAccount) -> SyncedFolder? {
        allFolders(of: account).first { $0.detectedRole == role }
    }

    // MARK: Choices

    /// Changes an account's folder choices: saved in its `account.json`, applied to the folders on
    /// record at once (so the sidebar, actions, cleanup and sending use them now), and the sync
    /// starts again when which folders sync or the special folders changed.
    func updateMailboxSettings(_ id: MailAccountID, _ change: (inout MailboxSettings) -> Void) async throws {
        guard let store = mailStore, var account = accounts.first(where: { $0.id == id }) else { return }
        let before = account.mailboxSettings
        var settings = before
        change(&settings)
        guard settings != before else { return }
        account.mailboxSettings = settings
        // The sync records the roles on every listing from the choices it started with, so a
        // change to either restarts it; the sidebar's own choices (shown, order) don't.
        let syncSees = settings.notSynced != before.notSynced || settings.specialFolders != before.specialFolders
        try await save(account, store: store, restartingSync: syncSees)
    }

    func setSyncs(_ syncs: Bool, folder: String, account: MailAccountID) async throws {
        try await updateMailboxSettings(account) { $0.setSyncs(syncs, folder: folder) }
    }

    func setShows(_ shows: Bool, folder: String, account: MailAccountID) async throws {
        try await updateMailboxSettings(account) { $0.setShows(shows, folder: folder) }
    }

    /// Chooses the folder for a role; `nil` goes back to the one the provider marked.
    func setSpecialFolder(_ folder: String?, for role: String, account: MailAccountID) async throws {
        try await updateMailboxSettings(account) { $0.setSpecialFolder(folder, for: role) }
    }

    /// Moves folders in the sidebar order, as a list's `onMove` gives them.
    func moveFolders(fromOffsets source: IndexSet, toOffset destination: Int, account id: MailAccountID) async throws {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        var names = settingsFolders(of: account).map(\.name)
        names.moveElements(fromOffsets: source, toOffset: destination)
        try await updateMailboxSettings(id) { $0.order = names }
    }

    /// Back to the provider's order.
    func resetFolderOrder(account: MailAccountID) async throws {
        try await updateMailboxSettings(account) { $0.order = [] }
    }

    // MARK: Folders at the provider (MAIL-095)

    /// Makes a folder at the provider, inside `parent` when given.
    @discardableResult
    func createFolder(named name: String, in parent: SyncedFolder?, account: MailAccountID) async throws -> String {
        try await editFolders(account) { editor, settings in
            try await editor.create(path: (parent?.path ?? []) + [name], settings: settings)
        }
    }

    /// Renames a folder at the provider, keeping it where it is in the hierarchy. The mail
    /// already here stays and is not downloaded again; the folder's choices follow it.
    @discardableResult
    func renameFolder(_ folder: SyncedFolder, to name: String, account: MailAccountID) async throws -> String {
        let renamed = try await editFolders(account) { editor, settings in
            try await editor.rename(folder.name, to: Array(folder.path.dropLast()) + [name], settings: settings)
        }
        if selection == .folder(account, folder.name) { await select(.folder(account, renamed)) }
        return renamed
    }

    /// Deletes a folder and the mail in it at the provider. Ask first: it can't be undone there.
    /// The copies here stay, marked deleted at the provider, unless the account removes mail
    /// deleted elsewhere (MAIL-075).
    func deleteFolder(_ folder: SyncedFolder, account: MailAccountID) async throws {
        _ = try await editFolders(account) { editor, settings in
            try await editor.delete(folder.name, settings: settings)
        }
    }

    /// How many stored messages are in a folder, for the delete confirmation.
    func storedCount(in folder: String, account: MailAccountID) async -> Int? {
        try? await mailStore?.messageCount(account: account, mailbox: folder)
    }

    /// Runs one folder edit with the account's sync stopped (a pass must not record the folders
    /// as they were before), then saves the choices it changed and starts the sync again.
    private func editFolders(_ id: MailAccountID,
                             _ edit: (FolderEditor, MailboxSettings) async throws -> FolderEditor.Outcome) async throws -> String {
        guard let store = mailStore, var account = accounts.first(where: { $0.id == id }) else {
            throw MailProviderError.unsupported("this account isn’t here any more")
        }
        let editor = try sync.folderEditor(for: account, store: store)
        let wasSyncing = sync.isSyncing(id)
        if wasSyncing { await sync.stop(id) }
        let outcome: FolderEditor.Outcome
        do {
            outcome = try await edit(editor, account.mailboxSettings)
        } catch {
            if wasSyncing { await sync.start(account, store: store) }
            throw error
        }
        account.mailboxSettings = outcome.settings
        try await store.save(account)
        try await reloadAfterAccountChange()
        let folders = try await store.applyMailboxSettings(outcome.settings, account: id)
        if wasSyncing { await sync.start(account, store: store) }
        sync.setFolders(folders, for: id)
        await registerForSending([account])
        return outcome.folder
    }

    /// Saves an account whose folder choices changed and applies them everywhere at once.
    private func save(_ account: MailAccount, store: MailStore, restartingSync: Bool) async throws {
        try await store.save(account)
        try await reloadAfterAccountChange()
        let folders = try await store.applyMailboxSettings(account.mailboxSettings, account: account.id)
        if restartingSync, account.connection != nil, sync.isSyncing(account.id) {
            await sync.stop(account.id)
            await sync.start(account, store: store)
        }
        sync.setFolders(folders, for: account.id)
        guard account.connection != nil else { return }
        // The Sent folder sending files copies in may have changed.
        await registerForSending([account])
    }

    // MARK: Servers (MAIL-096)

    /// New servers for an account, and a new password when given (else the one in the Keychain).
    /// Both servers are checked before anything is saved; then the sync starts again with them.
    func updateServers(_ id: MailAccountID, imap: MailServerSettings, smtp: MailServerSettings,
                       password: String) async throws(AccountSetupError) {
        guard let store = mailStore, var account = accounts.first(where: { $0.id == id }), let current = account.connection else {
            throw .refused(.incoming, host: "", detail: "This account isn’t connected.")
        }
        guard !imap.host.trimmingCharacters(in: .whitespaces).isEmpty else { throw .missingField("incoming mail server") }
        guard !smtp.host.trimmingCharacters(in: .whitespaces).isEmpty else { throw .missingField("outgoing mail server") }
        guard (1...65535).contains(imap.port), (1...65535).contains(smtp.port) else { throw .missingField("port (1 to 65535)") }
        let secret: Secret
        if !password.isEmpty {
            secret = Secret(password)
        } else {
            do {
                guard let saved = try sync.services.credentials.secret(for: id) else {
                    throw AccountSetupError.missingField(current.kind == .iCloud ? "app-specific password" : "password")
                }
                secret = saved
            } catch let error as AccountSetupError {
                throw error
            } catch {
                throw .keychain(String(describing: error))
            }
        }
        var connection = current
        connection.imap = MailServerSettings(host: imap.host.trimmingCharacters(in: .whitespaces), port: imap.port,
                                             security: imap.security, username: imap.username.trimmingCharacters(in: .whitespaces))
        connection.smtp = MailServerSettings(host: smtp.host.trimmingCharacters(in: .whitespaces), port: smtp.port,
                                             security: smtp.security, username: smtp.username.trimmingCharacters(in: .whitespaces))
        let verified = try await sync.services.verifier.verify(connection, password: secret)
        guard !Task.isCancelled else { throw .cancelled }
        if !password.isEmpty {
            do { try sync.services.credentials.save(secret, for: id) } catch { throw .keychain(String(describing: error)) }
        }
        account.connection = verified
        do {
            try await store.save(account)
            try await reloadAfterAccountChange()
        } catch {
            throw .refused(.incoming, host: verified.imap.host, detail: "The account couldn’t be saved in the mail folder: \(error)")
        }
        await sync.stop(id)
        await sync.start(account, store: store)
        await registerForSending([account])
    }
}

/// What a folder edit's failure says, in words.
enum FolderEditText {
    static func message(_ error: any Error, doing what: String) -> String {
        guard let error = error as? MailProviderError else { return "The folder couldn’t be \(what): \(error.localizedDescription)" }
        switch error {
        case .invalidName(let reason): return "The folder couldn’t be \(what): \(reason.prefix(1).uppercased() + reason.dropFirst())."
        case .authenticationFailed: return "The folder couldn’t be \(what): the provider refused the password. Enter it again in the account’s settings."
        case .connectionFailed, .connectionLost, .timedOut: return "The folder couldn’t be \(what): the provider can’t be reached. Try again when you’re online."
        case .folderNotFound: return "That folder is no longer at the provider."
        case .commandFailed(let detail): return "The provider refused: \(detail)"
        default: return "The folder couldn’t be \(what): \(error.description)"
        }
    }
}
