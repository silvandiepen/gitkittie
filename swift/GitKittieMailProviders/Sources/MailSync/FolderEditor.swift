import Foundation
import MailCore
import MailProvider
import MailStore

/// Creates, renames and deletes folders at the provider (GKM-066, MAIL-095), each in a session of
/// its own, and brings the folders on record in step at once, so the sidebar and settings show
/// the change before the next sync.
///
/// The account's sync must not run meanwhile: a pass that listed the folders before the change
/// would record that older list after it. The app stops the account's sync, edits, and starts it
/// again.
public struct FolderEditor: Sendable {
    public let account: MailAccountID
    private let connector: any MailboxConnector
    private let store: MailStore
    private let log: MailLog

    public init(account: MailAccountID, connector: any MailboxConnector, store: MailStore, log: MailLog = .disabled) {
        self.account = account
        self.connector = connector
        self.store = store
        self.log = log
    }

    /// What a rename or delete did to the account's folder choices, to be saved with the account.
    public struct Outcome: Sendable, Equatable {
        /// The folder's id at the provider after the change (the new one after a rename).
        public var folder: String
        /// The account's choices with the folder (and those inside it) followed or forgotten.
        public var settings: MailboxSettings
    }

    /// Makes a folder at `path` (["Projects"], or ["Projects", "2026"] inside Projects). Throws
    /// ``MailProviderError/invalidName(_:)`` when the name can't be used or is taken.
    public func create(path: [String], settings: MailboxSettings) async throws -> Outcome {
        try await connector.withSession { session in
            let id = try await session.folderID(for: path)
            guard try await !session.listFolders().contains(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
                throw MailProviderError.invalidName("there is a folder with that name already")
            }
            try await session.createFolder(id)
            log.info("folders", "created \(id)")
            try await record(session, settings: settings)
            return Outcome(folder: id, settings: settings)
        }
    }

    /// Renames a folder (and the folders inside it) to `path`. The mail already downloaded from
    /// it is kept under the new name: nothing is downloaded again.
    public func rename(_ folder: String, to path: [String], settings: MailboxSettings) async throws -> Outcome {
        try await connector.withSession { session in
            let listed = try await session.listFolders()
            guard let current = listed.first(where: { $0.id == folder }) else { throw MailProviderError.folderNotFound(folder) }
            guard !MailboxSettings.fixedRoles.contains(current.role?.rawValue ?? "") else {
                throw MailProviderError.invalidName("\(current.displayName) can’t be renamed")
            }
            let id = try await session.folderID(for: path)
            guard id != folder else { return Outcome(folder: folder, settings: settings) }
            guard !listed.contains(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
                throw MailProviderError.invalidName("there is a folder with that name already")
            }
            let delimiter = try await session.hierarchyDelimiter()
            try await session.renameFolder(folder, to: id)
            log.info("folders", "renamed \(folder) to \(id)")
            try await store.renameSyncedFolder(folder, to: id, delimiter: delimiter, account: account)
            var updated = settings
            updated.renameFolder(folder, to: id, delimiter: delimiter)
            try await record(session, settings: updated)
            return Outcome(folder: id, settings: updated)
        }
    }

    /// Deletes a folder at the provider, with the mail in it. The copies downloaded here stay,
    /// marked as deleted at the provider, unless the account removes mail deleted elsewhere
    /// (MAIL-075): the next sync decides, as for a folder deleted in another app.
    public func delete(_ folder: String, settings: MailboxSettings) async throws -> Outcome {
        try await connector.withSession { session in
            let listed = try await session.listFolders()
            guard let current = listed.first(where: { $0.id == folder }) else { throw MailProviderError.folderNotFound(folder) }
            guard !MailboxSettings.fixedRoles.contains(current.role?.rawValue ?? "") else {
                throw MailProviderError.invalidName("\(current.displayName) can’t be deleted")
            }
            let delimiter = try await session.hierarchyDelimiter()
            try await session.deleteFolder(folder)
            log.info("folders", "deleted \(folder)")
            var updated = settings
            // Folders inside it may stay at the provider (IMAP deletes only the one); the listing
            // below keeps those, and the choices made for them are dropped with the parent's.
            updated.removeFolder(folder, delimiter: delimiter)
            try await record(session, settings: updated)
            return Outcome(folder: folder, settings: updated)
        }
    }

    /// Lists the folders again and records them, as a sync pass does.
    private func record(_ session: any MailboxSession, settings: MailboxSettings) async throws {
        let listed = SyncPlanner.order(try await session.listFolders().filter(\.isSelectable))
        try await store.replaceSyncedFolders(Self.recorded(listed, settings: settings), account: account)
    }

    /// The provider's folders as the store keeps them: each with the role the provider detected
    /// and the role in use once the account's choices apply (MAIL-094).
    static func recorded(_ folders: [RemoteFolder], settings: MailboxSettings) -> [SyncedFolder] {
        let roles = settings.effectiveRoles(detected: folders.map { ($0.id, $0.role?.rawValue) })
        return folders.map { folder in
            SyncedFolder(name: folder.id, path: folder.path, role: roles[folder.id] ?? folder.role?.rawValue,
                         detectedRole: .some(folder.role?.rawValue))
        }
    }
}
