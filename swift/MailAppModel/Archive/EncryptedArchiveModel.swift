import Foundation
import MailCore
import MailStore
import Observation

// Encrypted archive (GKM-032, MAIL-128..130): everything the person owns in one encrypted file,
// opened only by a recovery key that is shown once. The model holds the key while it is on
// screen and forgets it when the person has confirmed they saved it, or discards the archive.

/// An archive just written, while its recovery key is shown.
struct WrittenArchive: Equatable {
    var file: URL
    /// The key in its seven groups of four, as shown.
    var keyGroups: [String]
    var summary: String

    var keyText: String { keyGroups.joined(separator: "-") }
}

/// A restore that finished: the new mail folder and what is in it.
struct RestoredArchive: Equatable {
    var folder: URL
    var summary: String
}

@MainActor
@Observable
final class EncryptedArchiveModel {
    /// True while an archive is written or restored.
    fileprivate(set) var isWorking = false
    /// The archive just written; its key is on screen until `finish()` or `discard()`.
    fileprivate(set) var written: WrittenArchive?
    /// What the person types back to show they saved the key: its last group.
    var confirmation = ""
    /// The last restore, until its notice is closed.
    var restored: RestoredArchive?
    /// Why the last write or restore failed, in words; cleared when shown.
    var error: String?

    /// True when the typed group matches the key's last group (any case, dashes and spaces
    /// ignored, O read as zero and I or L as one, as the key itself is read).
    var isConfirmed: Bool {
        guard let last = written?.keyGroups.last else { return false }
        return Self.normalized(confirmation) == last
    }

    /// The text of a saved key file: the key, which archive it opens, and what it is for.
    var keyFileText: String? {
        guard let written else { return nil }
        return """
            GitKittie Mail recovery key

            Archive: \(written.file.lastPathComponent)
            Recovery key: \(written.keyText)

            This key is the only way to open the archive. GitKittie Mail keeps no copy, and no one can \
            recover the mail without it. Keep it somewhere other than the archive itself: anyone who \
            has both can read the mail.

            """
    }

    /// The name a saved key file is suggested under.
    var keyFileName: String? {
        written.map { "\($0.file.deletingPathExtension().lastPathComponent) Recovery Key.txt" }
    }

    /// Closes the key once the person has confirmed they saved it. The key is gone from the app
    /// with it.
    @discardableResult
    func finish() -> Bool {
        guard isConfirmed else { return false }
        written = nil
        confirmation = ""
        return true
    }

    /// Without its key an archive can never be opened, so closing the key without confirming
    /// removes the archive.
    func discard() {
        guard let file = written?.file else { return }
        written = nil
        confirmation = ""
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            self.error = "The archive “\(file.lastPathComponent)” couldn’t be removed: \(error.localizedDescription). Without its recovery key it can’t be opened; delete it in Finder."
        }
    }

    static func normalized(_ typed: String) -> String {
        String(typed.uppercased().compactMap { character -> Character? in
            if character == "-" || character.isWhitespace { return nil }
            switch character {
            case "O": return "0"
            case "I", "L": return "1"
            default: return character
            }
        })
    }

    static func summary(of result: EncryptedArchiveResult) -> String {
        var text = "\(result.messages) \(result.messages == 1 ? "message" : "messages")"
        if result.attachments > 0 { text += " and \(result.attachments) \(result.attachments == 1 ? "attachment" : "attachments")" }
        text += ", with your spaces, rules and corrections, encrypted into “\(result.file.lastPathComponent)”."
        if !result.failed.isEmpty {
            text += " \(result.failed.count) \(result.failed.count == 1 ? "message was" : "messages were") left out because the original no longer matches its recorded hash."
        }
        if !result.partial.isEmpty {
            text += " \(result.partial.count) \(result.partial.count == 1 ? "message was" : "messages were") left out because \(result.partial.count == 1 ? "its" : "their") attachments aren’t downloaded yet; make another archive when you’re online."
        }
        return text
    }
}

extension AppModel {
    /// Writes an encrypted archive of everything into `folder` (from an open panel) and shows
    /// its recovery key. Messages with attachments still at the provider are downloaded first
    /// where they can be (GKM-036), as for export (MAIL-044).
    func writeEncryptedArchive(to folder: URL) async {
        guard let store = mailStore, !encryptedArchive.isWorking else { return }
        encryptedArchive.isWorking = true
        defer { encryptedArchive.isWorking = false }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        do {
            for account in accounts {
                await completePartialMessages(try await store.partialMessages(in: .account(account.id)))
            }
            let result = try await store.writeEncryptedArchive(to: folder)
            encryptedArchive.confirmation = ""
            encryptedArchive.written = WrittenArchive(file: result.file, keyGroups: result.recoveryKey.groups,
                                                      summary: EncryptedArchiveModel.summary(of: result))
        } catch {
            encryptedArchive.error = String(describing: error)
        }
    }

    /// Restores `archive` with the typed recovery key into a new folder, "Restored Mail", inside
    /// `parent`, with its own device state beside the standard one, as a chosen mail folder has
    /// (`MailFolderLocation`). The current mail folder is not touched; `useRestoredMail()`
    /// switches to the restored one.
    func restoreEncryptedArchive(_ archive: URL, recoveryKey typed: String, into parent: URL) async {
        guard !encryptedArchive.isWorking else { return }
        let key: ArchiveRecoveryKey
        do {
            key = try ArchiveRecoveryKey(typed)
        } catch {
            encryptedArchive.error = String(describing: error)
            return
        }
        encryptedArchive.isWorking = true
        defer { encryptedArchive.isWorking = false }
        let scopedArchive = archive.startAccessingSecurityScopedResource()
        let scopedParent = parent.startAccessingSecurityScopedResource()
        defer {
            if scopedArchive { archive.stopAccessingSecurityScopedResource() }
            if scopedParent { parent.stopAccessingSecurityScopedResource() }
        }
        do {
            let standard = try standardLocations()
            let target = try Self.freeRestoreLocations(in: parent, standard: standard)
            let result: EncryptedArchiveRestoreResult
            do {
                result = try await Task.detached(priority: .userInitiated) {
                    try EncryptedArchive.restore(archive, recoveryKey: key, into: target)
                }.value
            } catch {
                // Nothing was restored; the empty folder made for it goes too.
                try? FileManager.default.removeItem(at: target.mailFolder)
                throw error
            }
            encryptedArchive.restored = RestoredArchive(
                folder: target.mailFolder,
                summary: "\(result.messages) \(result.messages == 1 ? "message" : "messages") restored into “\(target.mailFolder.lastPathComponent)”. Use it as your mail folder to see them; each account asks for its password again.")
        } catch {
            encryptedArchive.error = String(describing: error)
        }
    }

    /// Switches to the folder the last restore made.
    func useRestoredMail() async {
        guard let folder = encryptedArchive.restored?.folder else { return }
        encryptedArchive.restored = nil
        await useMailFolder(folder)
    }

    /// "Restored Mail", or "Restored Mail 2"…, made empty here so its path is final (the device
    /// folder is named by the resolved path, `MailFolderLocation`), with a device folder that is
    /// new too.
    static func freeRestoreLocations(in parent: URL, standard: StoreLocations) throws -> StoreLocations {
        let fileManager = FileManager.default
        var counter = 1
        while true {
            let name = counter == 1 ? "Restored Mail" : "Restored Mail \(counter)"
            counter += 1
            let folder = parent.appendingPathComponent(name, isDirectory: true)
            guard !fileManager.fileExists(atPath: folder.path) else { continue }
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
            let locations = MailFolderLocation.locations(for: folder, standard: standard)
            if !fileManager.fileExists(atPath: locations.deviceFolder.path) { return locations }
            // Another folder once had this path and left its device state: not ours to reuse.
            try fileManager.removeItem(at: folder)
        }
    }
}
