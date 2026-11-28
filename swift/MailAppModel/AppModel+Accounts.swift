import Foundation
import MailAccounts
import MailCore
import MailOutbox
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
        if let reason = writeRefusal { throw .refused(.incoming, host: "", detail: reason) }
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

        let account = MailAccount(displayName: draft.displayName, address: address, connection: verified,
                                  senderName: draft.trimmedSenderName)
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
        await registerForSending([account])
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
        if let current = accounts.first(where: { $0.id == id }) {
            await sync.start(current, store: store)
            await registerForSending([current])
        }
    }

    /// Account settings (MAIL-074, MAIL-075): the sidebar name, "Your name" on sent mail, and
    /// whether mail deleted at the provider is removed here too. Saved in the account's
    /// `account.json`; sending takes the new name at once, and the sync starts again when the
    /// removal choice changed (it applies from its next pass).
    func updateAccountSettings(_ id: MailAccountID, displayName: String, senderName: String,
                               removesMailDeletedElsewhere: Bool) async throws {
        guard let store = mailStore, var account = accounts.first(where: { $0.id == id }) else { return }
        let label = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let removalChanged = account.removesDeletedMail != removesMailDeletedElsewhere
        if !label.isEmpty { account.displayName = label }
        account.senderName = name.isEmpty ? nil : name
        account.removesMailDeletedElsewhere = removesMailDeletedElsewhere ? true : nil
        try await store.save(account)
        try await reloadAfterAccountChange()
        guard account.connection != nil else { return }
        await registerForSending([account])
        if removalChanged, sync.isSyncing(id) {
            await sync.stop(id)
            await sync.start(account, store: store)
        }
    }

    /// Disconnects an account: stops its sync, removes its password from the Keychain and this
    /// device's sync state, and keeps, exports or removes its mail. Never touches the provider.
    func removeAccount(_ id: MailAccountID, _ removal: AccountRemoval) async throws {
        guard let store = mailStore else { return }
        // Before anything stops: a read-only folder can't lose or change an account.
        try store.requireWritable()
        await sync.stop(id)
        await unregisterFromSending(id)
        if case .exportThenRemove(let destination) = removal {
            // The copy first; if it fails, nothing is removed.
            try await store.exportAccount(id, to: destination)
        }
        try await store.disconnectAccount(id, mail: removal == .keepMail ? .keep : .remove)
        try sync.services.credentials.delete(for: id)
        sync.forget(id)
        if selection.account == id, removal != .keepMail { await select(.category(.focused)) }
        try await reloadAfterAccountChange()
    }

    /// Shows the mail in another folder (MAIL-021). The current folder is left as it is; its
    /// accounts come back when it is chosen again.
    func useMailFolder(_ url: URL?) async {
        // In iCloud Drive or a folder another app syncs (GKM-103, MAIL-126): refused before
        // anything stops, so the current folder carries on as it was.
        if let url, let refusal = mailFolderRefusal(for: url) {
            actionError = refusal
            return
        }
        await sync.stopAll()
        let location = MailFolderLocation(defaults: sync.services.defaults)
        do {
            if let url { try location.choose(url) } else { location.reset() }
        } catch {
            actionError = "That folder can’t be used: \(error.localizedDescription)"
        }
        await open()
    }

    /// Why a folder the person picked can't be the mail folder (GKM-103, MAIL-126): it is in
    /// iCloud Drive or a folder another app syncs. Nil when it can.
    func mailFolderRefusal(for url: URL) -> String? {
        sync.services.folderPlacement(url).refusal
    }

    /// The sidebar's line for an account's sync.
    func syncStatus(_ id: MailAccountID) -> String? {
        guard let account = accounts.first(where: { $0.id == id }) else { return nil }
        guard account.connection != nil else { return "Not connected · mail kept on \(DeviceWords.this)" }
        // The mail folder holds the sync back (GKM-103): nothing else about it is news.
        if let hold = sync.folderHold?.shortText { return hold }
        // Paused for space (MAIL-106): the coordinator's last progress would still say "Downloading".
        let syncLine = sync.isPausedForSpace(id) ? DownloadPause.shortText : SyncStatusText.line(sync.progress[id])
        // A stop on this device says what to do as well (GKM-091).
        let advice = sync.isPausedForSpace(id) ? nil : SyncStatusText.advice(sync.progress[id])
        let lines = [syncLine, advice, ActionStatusText.line(sync.replay[id])].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
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
        case .allMail, .category, .drafts, .outbox, .space, .attachments, .senders, .cleanup: nil
        case .account(let id), .folder(let id, _): id
        }
    }
}

// MARK: - Sending (GKM-014)

extension AppModel {
    /// Makes connected accounts available to the outbox: the same servers, trust and Keychain
    /// item (service, account id) as setup and sync, so what was verified is what sends.
    func registerForSending(_ accounts: [MailAccount]) async {
        guard let registry = sending?.registry else { return }
        for account in accounts {
            guard let connection = account.connection else {
                await registry.remove(account.id)
                continue
            }
            let connections = sync.services.connections
            let sentFolder = sync.folders[account.id]?.first { $0.role == "sent" }?.name
            await registry.register(SendingAccountSettings(
                account: account,
                smtp: connections.endpoint(connection.smtp),
                imap: connections.endpoint(connection.imap),
                credential: CredentialReference(service: sync.services.credentials.service, account: account.id.rawValue,
                                                username: connection.smtp.username),
                sentCopy: Self.sentCopyPolicy(connection.kind),
                sentFolder: sentFolder))
        }
    }

    func unregisterFromSending(_ id: MailAccountID) async {
        await sending?.registry.remove(id)
    }

    /// Gmail files every submission in Sent itself; iCloud is not known yet (MAIL-023);
    /// other IMAP hosts keep nothing.
    static func sentCopyPolicy(_ kind: MailAccountKind) -> SentCopyPolicy {
        switch kind {
        case .gmail: .providerFiles
        case .iCloud: .detect
        case .imap: .append
        }
    }
}
