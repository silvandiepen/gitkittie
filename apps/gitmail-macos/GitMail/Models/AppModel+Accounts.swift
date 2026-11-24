import Foundation
import MailAccounts
import MailCore
import MailProvider
import MailStore
import MailSync

/// What happens to an account's mail when it is removed (GKM-010).
enum AccountRemoval: Equatable {
    /// The mail stays in the folder, readable and searchable; nothing syncs it any more.
    case keepMail
    /// A copy goes to this folder first, then the mail is removed from the mail folder.
    case exportThenRemove(URL)
    /// The account's mail is removed from the mail folder.
    case removeMail
}

// Account setup and sync, as intents on the app model (GKM-010, GKM-011).
extension AppModel {
    /// Verifies the draft against both servers, then saves the password in the Keychain and the
    /// account (without it) in the mail folder, and starts syncing. Nothing is saved when any
    /// step fails; the error says which and why.
    @discardableResult
    func addAccount(_ draft: AccountDraft) async throws(AccountSetupError) -> MailAccount {
        guard let store = mailStore else { throw .refused(.incoming, host: "", detail: "The mail folder isn’t open.") }
        let connection = try draft.connection()
        let address = draft.trimmedAddress
        if accounts.contains(where: { $0.connection != nil && $0.address.lowercased() == address.lowercased()
                                      && $0.connection?.imap.host.lowercased() == connection.imap.host.lowercased() }) {
            throw .alreadyAdded(address: address)
        }
        let password = Secret(draft.password)
        let verified = try await sync.services.verifier.verify(connection, password: password)
        // Cancelled while the servers were being checked: nothing is saved.
        guard !Task.isCancelled else { throw .cancelled }

        let account = MailAccount(displayName: draft.displayName, address: address, connection: verified)
        do {
            try sync.services.credentials.save(password, for: account.id)
        } catch {
            throw .keychain(String(describing: error))
        }
        do {
            try await store.save(account)
        } catch {
            // The account is not there, so neither is its password.
            try? sync.services.credentials.delete(for: account.id)
            throw .refused(.incoming, host: verified.imap.host, detail: "The account couldn’t be saved in the mail folder: \(error)")
        }
        try? await reloadAfterAccountChange()
        await sync.start(account, store: store)
        return account
    }

    /// A new password for an account whose provider refused the old one (a revoked
    /// app-specific password). Verified first; then the sync starts again.
    func updatePassword(_ password: String, for id: MailAccountID) async throws(AccountSetupError) {
        guard let store = mailStore, let account = accounts.first(where: { $0.id == id }), let connection = account.connection else {
            throw .refused(.incoming, host: "", detail: "This account isn’t connected.")
        }
        guard !password.isEmpty else { throw .missingField(connection.kind == .iCloud ? "app-specific password" : "password") }
        let secret = Secret(password)
        let verified = try await sync.services.verifier.verify(connection, password: secret)
        do {
            try sync.services.credentials.save(secret, for: id)
        } catch {
            throw .keychain(String(describing: error))
        }
        if verified != connection {
            var updated = account
            updated.connection = verified
            try? await store.save(updated)
            try? await reloadAfterAccountChange()
        }
        await sync.stop(id)
        if let current = accounts.first(where: { $0.id == id }) { await sync.start(current, store: store) }
    }

    /// Disconnects an account: stops its sync, removes its password from the Keychain and this
    /// device's sync state, and keeps, exports or removes its mail. Never touches the provider.
    func removeAccount(_ id: MailAccountID, _ removal: AccountRemoval) async throws {
        guard let store = mailStore else { return }
        await sync.stop(id)
        if case .exportThenRemove(let destination) = removal {
            // The copy first; if it fails, nothing is removed.
            try await store.exportAccount(id, to: destination)
        }
        try await store.disconnectAccount(id, mail: removal == .keepMail ? .keep : .remove)
        try sync.services.credentials.delete(for: id)
        sync.forget(id)
        if selection.account == id, removal != .keepMail { await select(.allMail) }
        try await reloadAfterAccountChange()
    }

    /// Shows the mail in another folder (MAIL-021). The current folder is left as it is; its
    /// accounts come back when it is chosen again.
    func useMailFolder(_ url: URL?) async {
        await sync.stopAll()
        let location = MailFolderLocation(defaults: sync.services.defaults)
        do {
            if let url { try location.choose(url) } else { location.reset() }
        } catch {
            actionError = "That folder can’t be used: \(error.localizedDescription)"
        }
        await open()
    }

    /// The sidebar's line for an account's sync.
    func syncStatus(_ id: MailAccountID) -> String? {
        guard let account = accounts.first(where: { $0.id == id }) else { return nil }
        guard account.connection != nil else { return "Not connected · mail kept on this Mac" }
        return SyncStatusText.line(sync.progress[id])
    }

    func needsPassword(_ id: MailAccountID) -> Bool {
        SyncStatusText.needsPassword(sync.progress[id])
    }

    /// True when the folder is the default one in the app's container.
    var usesDefaultMailFolder: Bool {
        sync.services.defaults.data(forKey: MailFolderLocation.bookmarkKey) == nil
    }
}

extension SidebarSelection {
    /// The account the selection belongs to, if any.
    var account: MailAccountID? {
        switch self {
        case .allMail: nil
        case .account(let id), .folder(let id, _): id
        }
    }
}
