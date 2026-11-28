import Foundation
import MailCore

// Disconnecting an account (GKM-010; ThreatModel.md §12, "Account disconnect wiping local
// files"): the person chooses to keep the mail, export it first, or remove it. Nothing here
// touches the provider: disconnecting never deletes mail there.

/// What happens to an account's mail in the folder when it is disconnected.
public enum AccountMailDisposition: Sendable, Equatable {
    /// The mail stays in the folder and in the app, readable and searchable; nothing syncs it.
    case keep
    /// The account's messages and the attachments only they use are deleted from the folder.
    case remove
}

extension MailStore {
    /// Disconnects an account: forgets this device's sync state for it, and keeps or removes
    /// its mail. The sync for the account must be stopped first.
    public func disconnectAccount(_ id: MailAccountID, mail disposition: AccountMailDisposition) throws {
        try requireWritable()
        let name = try SafePath.component(id.rawValue)
        let accountFolder = locations.accountsFolder.appendingPathComponent(name, isDirectory: true)
        let fileManager = FileManager.default

        // Device state first: closing the mapping before its file goes.
        mappings[name] = nil
        let state = locations.stateFolder(name)
        if fileManager.fileExists(atPath: state.path) { try fileManager.removeItem(at: state) }

        switch disposition {
        case .keep:
            if var account = try accounts().first(where: { $0.id == id }) {
                account.connection = nil
                try save(account)
            }
        case .remove:
            if fileManager.fileExists(atPath: accountFolder.path) { try fileManager.removeItem(at: accountFolder) }
            // Partial messages (GKM-036) are device state of this account; their cached parts
            // become unreferenced and go with the next eviction.
            let partial = partialDirectory(account: name)
            if fileManager.fileExists(atPath: partial.path) { try fileManager.removeItem(at: partial) }
            try index.removeAccount(id)
            try removeUnreferencedBlobs()
            invalidateClassificationContext()
        }
    }

    /// Copies an account's mail into `destination` as a mail folder of its own: the originals
    /// (`.eml`, complete with their attachments), the derived Markdown, `account.json`, and the
    /// attachment blobs the Markdown links to, in the same layout, so the links keep working.
    /// Returns the folder it made. Never overwrites: an existing name gets a number.
    @discardableResult
    public func exportAccount(_ id: MailAccountID, to destination: URL) throws -> URL {
        let name = try SafePath.component(id.rawValue)
        let source = locations.accountsFolder.appendingPathComponent(name, isDirectory: true)
        let fileManager = FileManager.default
        let account = try accounts().first { $0.id == id }
        let base = SafePath.displayFileName("\(account?.displayName ?? name) Mail")
        var target = destination.appendingPathComponent(base, isDirectory: true)
        var counter = 2
        while fileManager.fileExists(atPath: target.path) {
            target = destination.appendingPathComponent("\(base) \(counter)", isDirectory: true)
            counter += 1
        }
        let staging = destination.appendingPathComponent(".\(base).export-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            let accounts = staging.appendingPathComponent("accounts", isDirectory: true)
            try fileManager.createDirectory(at: accounts, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: accounts.appendingPathComponent(name, isDirectory: true))
            }
            let blobs = staging.appendingPathComponent("blobs", isDirectory: true)
            try fileManager.createDirectory(at: blobs, withIntermediateDirectories: true)
            for blob in try referencedBlobs(in: [source]).sorted() {
                let file = locations.blobsFolder.appendingPathComponent(blob)
                guard fileManager.fileExists(atPath: file.path) else { continue }
                try fileManager.copyItem(at: file, to: blobs.appendingPathComponent(blob))
            }
            try fileManager.copyItem(at: locations.layoutURL, to: staging.appendingPathComponent("layout.json"))
            // Whole or nothing: the export appears under its name only once every file is in.
            try fileManager.moveItem(at: staging, to: target)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return target
    }

    // MARK: Blobs

    /// Deletes blobs that no remaining message links to.
    func removeUnreferencedBlobs() throws {
        try requireWritable()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: locations.blobsFolder.path) else { return }
        let accountFolders = fileManager.fileExists(atPath: locations.accountsFolder.path)
            ? try sortedContents(of: locations.accountsFolder) : []
        let referenced = try referencedBlobs(in: accountFolders)
        for file in try sortedContents(of: locations.blobsFolder) where SafePath.isSHA256Hex(file.lastPathComponent) {
            if !referenced.contains(file.lastPathComponent) { try fileManager.removeItem(at: file) }
        }
    }

    /// The blobs the `.md` files under these account folders link to.
    private func referencedBlobs(in accountFolders: [URL]) throws -> Set<String> {
        let fileManager = FileManager.default
        var result = Set<String>()
        for folder in accountFolders {
            let messages = folder.appendingPathComponent("messages", isDirectory: true)
            guard let walker = fileManager.enumerator(at: messages, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where file.pathExtension == "md" {
                guard let markdown = try? String(contentsOf: file, encoding: .utf8),
                      let front = try? DerivedMarkdown.frontMatter(of: markdown) else {
                    // A Markdown file that cannot be read keeps every blob: never delete on doubt.
                    return Set(try sortedContents(of: locations.blobsFolder).map(\.lastPathComponent))
                }
                for attachment in front.attachments { result.insert(attachment.blob) }
            }
        }
        return result
    }
}
