import Foundation
import MailCore

// Export (GKM-023; MAIL-003, MAIL-044): a message, a conversation, a space or an account,
// copied out as a mail folder of its own. The originals are the exact stored bytes (checked
// against their recorded hash), so any client that reads `.eml` sees what the provider sent;
// the Markdown copies and attachment blobs come with them in the same layout, so the Markdown's
// links keep working and the export can be opened as a mail folder. Device-local state (index,
// sync cursors and mapping, flags, folder memberships, extracted attachment text, remote-image
// choices, the outbox) is never part of it: none of it lives in the mail folder (MAIL-013), and
// the export copies only mail-folder files.

/// What to export.
public enum ExportSelection: Hashable, Sendable {
    case messages([MailMessageID])
    /// Every message of these conversations.
    case threads([String])
    /// Every stored message in a space, and the space's own file.
    case space(MailSpaceID)
    /// Every stored message in an account.
    case account(MailAccountID)
}

/// What an export wrote.
public struct ExportResult: Equatable, Sendable {
    /// The folder it made.
    public var folder: URL
    public var messages: Int
    public var attachments: Int
    /// Messages left out because their original no longer matches its recorded hash: a changed
    /// original is the person's to look at, never exported as if it were the message.
    public var failed: [MailMessageID]
    /// Partial messages left out (GKM-036, MAIL-062): their original is not downloaded yet, and
    /// what is stored of them is not the message. Complete them first (MailSync's
    /// `OnDemandFetcher.complete`), then export again.
    public var partial: [MailMessageID] = []
}

extension MailStore {
    /// Exports `selection` into a new folder inside `destination`, named `name` (or after the
    /// selection). Never overwrites: an existing name gets a number. The folder appears under its
    /// name only once every file is in; on any error nothing is left behind.
    @discardableResult
    public func export(_ selection: ExportSelection, to destination: URL, name: String? = nil) throws -> ExportResult {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MailStoreError.exportDestinationUnavailable(destination.lastPathComponent)
        }
        let ids = try exportedIDs(selection)
        let base = try SafePath.displayFileName(name ?? defaultExportName(selection, ids: ids))
        var target = destination.appendingPathComponent(base, isDirectory: true)
        var counter = 2
        while fileManager.fileExists(atPath: target.path) {
            target = destination.appendingPathComponent("\(base) \(counter)", isDirectory: true)
            counter += 1
        }
        let staging = destination.appendingPathComponent(".\(base).export-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        let plainWriter = AtomicWriter(faults: .none)
        var result = ExportResult(folder: target, messages: 0, attachments: 0, failed: [])
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            var blobs = Set<String>()
            var accounts = Set<MailAccountID>()
            var exported: [MailMessageID] = []
            for id in ids {
                // Files only, nothing parsed: the original is checked against the hash its
                // Markdown recorded and copied as it is.
                let (emlURL, isPartial) = try fileLocation(of: id)
                guard !isPartial else {
                    result.partial.append(id)
                    continue
                }
                let markdownURL = emlURL.deletingPathExtension().appendingPathExtension("md")
                let markdown = try Data(contentsOf: markdownURL)
                let front = try DerivedMarkdown.frontMatter(of: String(decoding: markdown, as: UTF8.self))
                let original = try Data(contentsOf: emlURL)
                guard Hashing.sha256Hex(original) == front.emlSha256 else {
                    result.failed.append(id)
                    continue
                }
                guard let relative = pathInMailFolder(emlURL) else { throw MailStoreError.messageNotFound(id.rawValue) }
                let emlTarget = staging.appendingPathComponent(relative)
                try plainWriter.write(original, to: emlTarget)
                try plainWriter.write(markdown, to: emlTarget.deletingPathExtension().appendingPathExtension("md"))
                for attachment in front.attachments { blobs.insert(attachment.blob) }
                accounts.insert(front.account)
                exported.append(id)
            }
            for blob in blobs.sorted() {
                try plainWriter.write(blobData(blob), to: staging.appendingPathComponent("blobs", isDirectory: true).appendingPathComponent(blob))
            }
            // Each account's description, without its servers: an export is for keeping or
            // handing on, and nothing in it should look like a sign-in.
            let known = try self.accounts()
            for account in accounts.sorted(by: { $0.rawValue < $1.rawValue }) {
                var description = known.first { $0.id == account } ?? MailAccount(id: account, displayName: account.rawValue, address: "")
                description.connection = nil
                let url = staging.appendingPathComponent("accounts", isDirectory: true)
                    .appendingPathComponent(try SafePath.component(account.rawValue), isDirectory: true)
                    .appendingPathComponent("account.json")
                try plainWriter.write(JSONCoding.prettyEncoder.encode(description), to: url)
            }
            if case .space(let spaceID) = selection {
                // The space comes along, holding only what was exported.
                var space = try self.space(spaceID)
                let included = Set(exported)
                space.members = space.members.filter { included.contains($0.message) }
                space.excluded = []
                try plainWriter.write(JSONCoding.prettyEncoder.encode(space),
                                      to: staging.appendingPathComponent("spaces", isDirectory: true).appendingPathComponent("\(spaceID.rawValue).json"))
            }
            try plainWriter.write(Data(contentsOf: locations.layoutURL), to: staging.appendingPathComponent("layout.json"))
            try fileManager.moveItem(at: staging, to: target)
            result.messages = exported.count
            result.attachments = blobs.count
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return result
    }

    /// The partial messages a selection covers (GKM-036): complete them before exporting, or
    /// the export leaves them out.
    public func partialMessages(in selection: ExportSelection) throws -> [(id: MailMessageID, account: MailAccountID)] {
        try exportedIDs(selection).compactMap { id in
            guard try index.location(of: id)?.isPartial == true, let account = try index.account(of: id) else { return nil }
            return (id, account)
        }
    }

    /// The stored messages a selection covers, oldest first within a thread, newest first otherwise.
    func exportedIDs(_ selection: ExportSelection) throws -> [MailMessageID] {
        switch selection {
        case .messages(let ids):
            var seen = Set<MailMessageID>()
            return try index.identities(of: ids).map(\.id).filter { seen.insert($0).inserted }
        case .threads(let threadIDs):
            var seen = Set<MailMessageID>()
            return try threadIDs.flatMap { try index.ids(inThread: $0) }.filter { seen.insert($0).inserted }
        case .space(let spaceID):
            let space = try self.space(spaceID)
            return try index.identities(of: space.members.map(\.message)).map(\.id)
        case .account(let account):
            var ids: [MailMessageID] = []
            while true {
                let page = try index.summaries(account: account, limit: 500, offset: ids.count)
                if page.isEmpty { break }
                ids += page.map(\.id)
            }
            return ids
        }
    }

    private func defaultExportName(_ selection: ExportSelection, ids: [MailMessageID]) throws -> String {
        switch selection {
        case .messages, .threads:
            let subject = try index.summaries(ids: Array(ids.suffix(1))).first?.subject?.trimmingCharacters(in: .whitespaces)
            return subject?.isEmpty == false ? subject! : "Exported Mail"
        case .space(let id):
            return try space(id).name
        case .account(let id):
            return "\(try accounts().first { $0.id == id }?.displayName ?? id.rawValue) Mail"
        }
    }

    /// A file's path relative to the mail folder, when it is inside it.
    private func pathInMailFolder(_ url: URL) -> String? {
        let root = locations.mailFolder.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > root.count, Array(parts.prefix(root.count)) == root else { return nil }
        return parts.dropFirst(root.count).joined(separator: "/")
    }
}
