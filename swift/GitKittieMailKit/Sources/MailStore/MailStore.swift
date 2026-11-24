import Foundation
import MailCore

// The mail folder and the device-local state (GKM-005). Layout: Architecture.md, Storage and
// identity. The index, cache and sync cursors never live inside the mail folder (MAIL-013).

/// The result of storing a message.
public struct IngestResult: Equatable, Sendable {
    public var id: MailMessageID
    /// False when the remote location was already mapped: nothing was written.
    public var isNew: Bool
}

/// A message read back from the folder.
public struct StoredMessage: Sendable {
    public var front: MessageFrontMatter
    /// The whole derived `.md`, front matter included.
    public var markdown: String
    public var emlURL: URL
    public var markdownURL: URL
    /// The plain-text body as the parser reads it from the `.eml`; `nil` when there is none.
    public var textBody: String?
    /// The HTML body as the sender wrote it. Hostile: only ever shown through MailHTML's
    /// sanitizer in the reader's locked-down web view (GKM-012).
    public var htmlBody: String?
    /// What the parser found malformed in the original, for the reader to say so.
    public var parseProblems: [String]

    public var hasHTMLBody: Bool { htmlBody != nil }

    /// The Markdown below the front matter.
    public var body: String {
        let parts = markdown.components(separatedBy: "\n---\n")
        return parts.count > 1 ? parts.dropFirst().joined(separator: "\n---\n").trimmingCharacters(in: .newlines) : markdown
    }
}

/// The mail store: EML originals, derived Markdown, attachment blobs, a rebuildable FTS5 index
/// and the remote mapping.
///
/// **A message exists when its `.eml` exists.** A write goes: journal entry (device folder) →
/// attachment blobs → `.md` → `.eml` (each staged, flushed and renamed into place) → index →
/// remote mapping → journal entry removed. Whatever stops it — a thrown error or a killed
/// process — the next `open` finishes or undoes it from the journal: an `.eml` that made it is
/// completed (Markdown, index, mapping); an `.md` without its `.eml` is removed; temporary files
/// are deleted. A failed write is deliberately not tidied up on the spot, so crashes and errors
/// share one recovery path, and that path is what the tests exercise.
public actor MailStore {
    /// Version of the folder layout, recorded in `Mail/layout.json`.
    public static let layoutVersion = 1

    public nonisolated let locations: StoreLocations
    private let parser: any MessageParsing
    let writer: AtomicWriter
    private let faults: WriteFaults
    var index: MailIndex
    var mappings: [String: RemoteMapping] = [:]

    private init(locations: StoreLocations, parser: any MessageParsing, faults: WriteFaults, index: MailIndex) {
        self.locations = locations
        self.parser = parser
        self.faults = faults
        self.writer = AtomicWriter(faults: faults)
        self.index = index
    }

    /// Opens (or creates) the store, finishes or undoes any write a crash interrupted, and
    /// rebuilds the index from the folder when it is missing, damaged or from another schema.
    public static func open(_ locations: StoreLocations, parser: any MessageParsing = MIMEMessageParser(),
                            faults: WriteFaults = .none) async throws -> MailStore {
        try locations.validate()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: locations.mailFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: locations.deviceFolder, withIntermediateDirectories: true)
        try checkLayout(locations)
        let store = MailStore(locations: locations, parser: parser, faults: faults, index: try openIndex(at: locations.indexURL))
        try await store.finishOpening()
        return store
    }

    private func finishOpening() throws {
        let journalWasReadable = try recoverInterruptedWrites()
        if index.needsRebuild || !journalWasReadable { try rebuildIndex() }
    }

    // MARK: - Writing

    /// Stores a message's original bytes, untouched, with its derived Markdown and attachment
    /// blobs, and indexes it. With a `remote` location already on record, nothing is written and
    /// the existing id comes back: fetching the same UID twice never makes two messages.
    @discardableResult
    public func ingest(_ eml: Data, account: MailAccountID, remote: RemoteLocation? = nil,
                       receivedAt: Date = Date(), flags: MessageFlags? = nil) throws -> IngestResult {
        let accountName = try SafePath.component(account.rawValue)
        if let remote, let existing = try mapping(for: accountName).localID(at: remote) {
            return IngestResult(id: existing, isNew: false)
        }
        let id = MailMessageID()
        // Whole seconds: the received date is stored as ISO 8601 and must read back equal.
        let received = Date(timeIntervalSince1970: receivedAt.timeIntervalSince1970.rounded(.down))
        let derived = try derive(eml, parsed: parser.parse(eml), id: id, account: account, received: received)
        let directory = try messageDirectory(account: accountName, date: derived.front.sortDate)

        let journalURL = locations.journalFolder.appendingPathComponent("\(id.rawValue).json")
        let entry = JournalEntry(id: id, account: account, directory: relativePath(of: directory), remote: remote, received: received)
        try writer.write(JSONCoding.encoder.encode(entry), to: journalURL)

        try storeBlobs(derived.blobs)
        let markdown = try writer.stage(Data(derived.markdown.utf8), for: directory.appendingPathComponent("\(id.rawValue).md"))
        let original = try writer.stage(eml, for: directory.appendingPathComponent("\(id.rawValue).eml"))
        try writer.commit(markdown)
        try writer.commit(original)

        try faults.check(.beforeIndex)
        try index.upsert(IndexRecord(front: derived.front, message: derived.message, path: relativePath(of: original.destination),
                                     attachmentText: attachmentText(for: derived.front.attachments)))
        if let remote {
            try mapping(for: accountName).record(remote, for: id)
            try index.setMailboxes([remote.mailbox], for: id, account: account)
        }
        if let flags {
            try mapping(for: accountName).setFlags(flags, for: id)
            try index.setFlags(flags, for: id)
        }
        try FileManager.default.removeItem(at: journalURL)
        return IngestResult(id: id, isNew: true)
    }

    /// Records the account's description in the folder (`accounts/<id>/account.json`). No
    /// credentials: those live in the Keychain.
    public func save(_ account: MailAccount) throws {
        let name = try SafePath.component(account.id.rawValue)
        let url = locations.accountsFolder.appendingPathComponent(name, isDirectory: true).appendingPathComponent("account.json")
        try writer.write(JSONCoding.prettyEncoder.encode(account), to: url)
    }

    // MARK: - Reading

    /// Every account in the folder, by display name. A folder without `account.json` (copied in
    /// by hand, or from a newer app) is listed under its id rather than hidden.
    public func accounts() throws -> [MailAccount] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: locations.accountsFolder.path) else { return [] }
        var result: [MailAccount] = []
        for folder in try fileManager.contentsOfDirectory(at: locations.accountsFolder, includingPropertiesForKeys: [.isDirectoryKey]) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let name = try? SafePath.component(folder.lastPathComponent) else { continue }
            let file = folder.appendingPathComponent("account.json")
            if fileManager.fileExists(atPath: file.path) {
                var account = try JSONCoding.decoder.decode(MailAccount.self, from: Data(contentsOf: file))
                account.id = MailAccountID(name)
                result.append(account)
            } else {
                result.append(MailAccount(id: MailAccountID(name), displayName: name, address: ""))
            }
        }
        return result.sorted { ($0.displayName.lowercased(), $0.id.rawValue) < ($1.displayName.lowercased(), $1.id.rawValue) }
    }

    public func messageCount() throws -> Int { try index.count() }

    /// Newest first.
    public func summaries(account: MailAccountID? = nil, limit: Int = 200, offset: Int = 0) throws -> [MessageSummary] {
        try index.summaries(account: account, limit: limit, offset: offset)
    }

    public func search(_ text: String, account: MailAccountID? = nil, limit: Int = 200) throws -> [MessageSummary] {
        try index.search(text, account: account, limit: limit)
    }

    /// Messages matching a search with filters (GKM-016): best text matches first, then newest.
    /// With no text, the filtered messages newest first. Reads the local index only: offline.
    public func search(_ query: SearchQuery, limit: Int = 200, offset: Int = 0) throws -> [MessageSummary] {
        try index.summaries(matching: query, limit: limit, offset: offset)
    }

    /// Conversations in a view (account, folder, unread…), newest activity first (GKM-012).
    public func threads(_ query: SearchQuery = SearchQuery(), limit: Int = 200, offset: Int = 0) throws -> [ThreadSummary] {
        try index.threads(matching: query, limit: limit, offset: offset)
    }

    /// Every message in a thread, oldest first.
    public func thread(_ threadID: String) throws -> [MessageSummary] {
        try index.thread(threadID)
    }

    public func unreadCount(account: MailAccountID? = nil, mailbox: String? = nil) throws -> Int {
        try index.unreadCount(account: account, mailbox: mailbox)
    }

    /// The folders that hold stored messages in an account (from this device's sync state).
    public func folders(account: MailAccountID) throws -> [String] {
        try index.mailboxes(account: account)
    }

    /// True when exactly these bytes are already stored in the account: an import of the same
    /// `.eml` twice is skipped, while a different message with the same Message-ID is not.
    public func containsOriginal(_ eml: Data, account: MailAccountID) throws -> Bool {
        try index.containsOriginal(sha256: Hashing.sha256Hex(eml), account: account)
    }

    // MARK: - Flags

    public func flags(of id: MailMessageID) throws -> MessageFlags {
        guard let account = try index.account(of: id) else { throw MailStoreError.messageNotFound(id.rawValue) }
        // What the window shows: the provider's flags with open changes laid over (GKM-015).
        return try effectiveState(of: id, mapping: mapping(for: SafePath.component(account.rawValue))).flags
    }

    /// Records the provider flags for a message (the sync calls this), or a local change such
    /// as "read" when the reader opens it. Kept in the device's sync state, mirrored in the index.
    public func setFlags(_ flags: MessageFlags, for id: MailMessageID) throws {
        guard let account = try index.account(of: id) else { throw MailStoreError.messageNotFound(id.rawValue) }
        try mapping(for: SafePath.component(account.rawValue)).setFlags(flags, for: id)
        try index.setFlags(flags, for: id)
    }

    // MARK: - Attachment text (GKM-016)

    /// Attachments of the given media types whose text has not been extracted yet. The caller
    /// extracts them (in an isolated process, ThreatModel §4) and hands the text back.
    public func attachmentsNeedingText(mediaTypes: Set<String>, limit: Int = 50) throws -> [(blob: String, mediaType: String)] {
        let done = Set((try? FileManager.default.contentsOfDirectory(atPath: attachmentTextFolder.path)) ?? [])
            .compactMap { $0.hasSuffix(".txt") ? String($0.dropLast(4)) : nil }
        return try index.blobs(ofTypes: Set(mediaTypes.map { $0.lowercased() }), excluding: Set(done), limit: limit)
    }

    /// Stores what extraction found for a blob (nil or empty: nothing, which is remembered so it
    /// is not tried again) and makes it searchable in every message carrying that blob. The
    /// text lives in the device cache, never in the mail folder.
    public func recordAttachmentText(_ text: String?, forBlob blob: String) throws {
        guard SafePath.isSHA256Hex(blob) else { throw MailStoreError.unsafePathComponent(blob) }
        try writer.write(Data((text ?? "").utf8), to: attachmentTextFolder.appendingPathComponent("\(blob).txt"))
        for (id, blobs) in try index.messages(withBlob: blob) {
            try index.setAttachmentText(blobs.compactMap(cachedText(forBlob:)).joined(separator: "\n"), for: id)
        }
    }

    private var attachmentTextFolder: URL { locations.cacheFolder.appendingPathComponent("attachment-text", isDirectory: true) }

    private func cachedText(forBlob blob: String) -> String? {
        guard SafePath.isSHA256Hex(blob) else { return nil }
        let text = try? String(contentsOf: attachmentTextFolder.appendingPathComponent("\(blob).txt"), encoding: .utf8)
        return text?.isEmpty == false ? text : nil
    }

    private func attachmentText(for attachments: [AttachmentReference]) -> String {
        attachments.compactMap { cachedText(forBlob: $0.blob) }.joined(separator: "\n")
    }

    public func message(_ id: MailMessageID) throws -> StoredMessage {
        let emlURL = try url(of: id)
        let markdownURL = emlURL.deletingPathExtension().appendingPathExtension("md")
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        let parsed = try parser.parse(Data(contentsOf: emlURL))
        return StoredMessage(front: try DerivedMarkdown.frontMatter(of: markdown), markdown: markdown, emlURL: emlURL,
                             markdownURL: markdownURL, textBody: parsed.textBody, htmlBody: parsed.htmlBody,
                             parseProblems: parsed.problems)
    }

    /// The original bytes, checked against the hash recorded when they were stored.
    public func originalData(of id: MailMessageID) throws -> Data {
        let stored = try message(id)
        let data = try Data(contentsOf: stored.emlURL)
        guard Hashing.sha256Hex(data) == stored.front.emlSha256 else {
            throw MailStoreError.integrityMismatch(path: relativePath(of: stored.emlURL))
        }
        return data
    }

    /// An attachment's bytes, checked against the hash that names them.
    public func attachmentData(_ reference: AttachmentReference) throws -> Data {
        guard SafePath.isSHA256Hex(reference.blob) else { throw MailStoreError.unsafePathComponent(reference.blob) }
        let url = locations.blobsFolder.appendingPathComponent(reference.blob)
        let data = try Data(contentsOf: url)
        guard Hashing.sha256Hex(data) == reference.blob else { throw MailStoreError.integrityMismatch(path: relativePath(of: url)) }
        return data
    }

    /// A blob's bytes by its hash, checked.
    public func blobData(_ blob: String) throws -> Data {
        guard SafePath.isSHA256Hex(blob) else { throw MailStoreError.unsafePathComponent(blob) }
        let url = locations.blobsFolder.appendingPathComponent(blob)
        let data = try Data(contentsOf: url)
        guard Hashing.sha256Hex(data) == blob else { throw MailStoreError.integrityMismatch(path: relativePath(of: url)) }
        return data
    }

    /// Checks every message's original and attachments against their recorded hashes; returns
    /// the ids that fail. Never repairs: an original that changed is the user's to look at.
    public func verifyIntegrity() throws -> [MailMessageID] {
        var failed: [MailMessageID] = []
        var offset = 0
        while true {
            let page = try index.summaries(account: nil, limit: 500, offset: offset)
            if page.isEmpty { break }
            for summary in page {
                do {
                    _ = try originalData(of: summary.id)
                    for attachment in try message(summary.id).front.attachments { _ = try attachmentData(attachment) }
                } catch MailStoreError.integrityMismatch {
                    failed.append(summary.id)
                }
            }
            offset += page.count
        }
        return failed.sorted()
    }

    // MARK: - Identity and reconciliation

    /// The local id stored for a provider location, if any.
    public func localID(at location: RemoteLocation, account: MailAccountID) throws -> MailMessageID? {
        try mapping(for: SafePath.component(account.rawValue)).localID(at: location)
    }

    public func remoteLocations(of id: MailMessageID, account: MailAccountID) throws -> [RemoteLocation] {
        try mapping(for: SafePath.component(account.rawValue)).locations(of: id)
    }

    /// Records that a stored message is (also) at `location`: after a move, or when the same
    /// message turns up in a second mailbox and reconciliation matched it.
    public func record(_ location: RemoteLocation, for id: MailMessageID, account: MailAccountID) throws {
        let mapping = try mapping(for: SafePath.component(account.rawValue))
        try mapping.record(location, for: id)
        try refreshIndex([id], account: account, mapping: mapping)
    }

    /// The message left `location` (moved or expunged at the provider). The local message stays.
    public func forget(_ location: RemoteLocation, account: MailAccountID) throws {
        let mapping = try mapping(for: SafePath.component(account.rawValue))
        let id = try mapping.localID(at: location)
        try mapping.forget(location)
        guard let id else { return }
        // Open moves out of that folder cannot happen any more and must not bring it back.
        try supersedeLocationRows(of: id, leaving: location.mailbox, mapping: mapping, now: Date())
        try refreshIndex([id], account: account, mapping: mapping)
    }

    /// The mailboxes this device has seen for the account.
    public func mailboxes(account: MailAccountID) throws -> [String] {
        try mapping(for: SafePath.component(account.rawValue)).mailboxes()
    }

    /// The server's UIDVALIDITY for a mailbox. When it changed, the old UIDs are void; the ids
    /// that no longer have any location come back for reconciliation.
    public func updateUIDValidity(_ uidValidity: UInt32, mailbox: String, account: MailAccountID) throws -> [MailMessageID] {
        let mapping = try mapping(for: SafePath.component(account.rawValue))
        let orphaned = try mapping.setUIDValidity(uidValidity, mailbox: mailbox)
        try index.setMembers(mapping.localIDs(inMailbox: mailbox), ofMailbox: mailbox, account: account)
        try reapplyOverlay(account: account, mapping: mapping, touching: mailbox)
        return orphaned
    }

    /// Stored messages in the account that may be the same message as `eml`: same Message-ID
    /// or same content fingerprint. Signals for the sync to weigh, never an automatic merge.
    public func reconciliationCandidates(for eml: Data, account: MailAccountID) throws -> [MailMessageID] {
        let parsed = try parser.parse(eml)
        return try index.candidates(account: account, messageID: parsed.messageID, fingerprint: ContentFingerprint.of(parsed))
    }

    // MARK: - Recovery and rebuild

    /// Makes the index again from the folder alone. Also removes what interrupted writes left
    /// (temporary files, a `.md` without its `.eml`) and rewrites a `.md` that no longer matches
    /// what the current parser derives from its `.eml` — so a better MIME parser refreshes them.
    public func rebuildIndex() throws {
        let fileManager = FileManager.default
        try removePartials(in: locations.blobsFolder)
        try index.replaceAll { insert in
            guard fileManager.fileExists(atPath: locations.accountsFolder.path) else { return }
            for accountFolder in try sortedContents(of: locations.accountsFolder) {
                guard let accountName = try? SafePath.component(accountFolder.lastPathComponent) else { continue }
                let messages = accountFolder.appendingPathComponent("messages", isDirectory: true)
                guard fileManager.fileExists(atPath: messages.path) else { continue }
                for year in try sortedContents(of: messages) where Int(year.lastPathComponent) != nil {
                    for month in try sortedContents(of: year) where Int(month.lastPathComponent) != nil {
                        try removePartials(in: month)
                        let files = try sortedContents(of: month)
                        let originals = Set(files.filter { $0.pathExtension == "eml" }.map { $0.deletingPathExtension().lastPathComponent })
                        for file in files where file.pathExtension == "md" && !originals.contains(file.deletingPathExtension().lastPathComponent) {
                            // Only an `.md` this store named (a UUID) is an orphan of an interrupted write.
                            if MailMessageID(file.deletingPathExtension().lastPathComponent) != nil { try fileManager.removeItem(at: file) }
                        }
                        for file in files where file.pathExtension == "eml" {
                            guard let id = MailMessageID(file.deletingPathExtension().lastPathComponent),
                                  id.rawValue == file.deletingPathExtension().lastPathComponent else { continue }
                            try insert(complete(id: id, account: MailAccountID(accountName), emlURL: file, fallbackReceived: nil))
                        }
                    }
                }
            }
        }
        try restoreDeviceState()
    }

    /// Folders and flags are device state (the sync's own database), not folder content: after
    /// the index is rebuilt from the folder, they are copied back in from there.
    private func restoreDeviceState() throws {
        let stateRoot = locations.deviceFolder.appendingPathComponent("state", isDirectory: true)
        guard FileManager.default.fileExists(atPath: stateRoot.path) else { return }
        for folder in try sortedContents(of: stateRoot) {
            guard let name = try? SafePath.component(folder.lastPathComponent), name != "journal",
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent("sync.sqlite").path) else { continue }
            let mapping = try mapping(for: name)
            try index.restore(flags: mapping.allFlags(), locations: mapping.allMemberships(), account: MailAccountID(name))
            // Changes not at the provider yet stay visible after a rebuild (GKM-015).
            try reapplyOverlay(account: MailAccountID(name), mapping: mapping)
        }
    }

    /// Finishes or undoes every write the journal still lists. Returns false when a journal
    /// entry was unreadable, so the caller rebuilds from the folder to be sure.
    private func recoverInterruptedWrites() throws -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: locations.journalFolder.path) else { return true }
        try removePartials(in: locations.journalFolder)
        try removePartials(in: locations.blobsFolder)
        var everyEntryReadable = true
        for file in try sortedContents(of: locations.journalFolder) where file.pathExtension == "json" {
            guard let entry = try? JSONCoding.decoder.decode(JournalEntry.self, from: Data(contentsOf: file)),
                  let accountName = try? SafePath.component(entry.account.rawValue),
                  let directory = safeDirectory(entry.directory) else {
                // Journal entries are written atomically, so this is damage from outside. The
                // folder is the truth: drop the entry and let the full rebuild sort it out.
                everyEntryReadable = false
                try fileManager.removeItem(at: file)
                continue
            }
            try removePartials(in: directory, prefix: ".\(entry.id.rawValue).")
            let emlURL = directory.appendingPathComponent("\(entry.id.rawValue).eml")
            let markdownURL = directory.appendingPathComponent("\(entry.id.rawValue).md")
            if fileManager.fileExists(atPath: emlURL.path) {
                try index.upsert(complete(id: entry.id, account: entry.account, emlURL: emlURL, fallbackReceived: entry.received))
                if let remote = entry.remote {
                    try mapping(for: accountName).record(remote, for: entry.id)
                    try index.setMailboxes(Set(mapping(for: accountName).locations(of: entry.id).map(\.mailbox)), for: entry.id, account: entry.account)
                }
            } else if fileManager.fileExists(atPath: markdownURL.path) {
                try fileManager.removeItem(at: markdownURL)
            }
            try fileManager.removeItem(at: file)
        }
        return everyEntryReadable
    }

    /// Brings one stored message up to date from its `.eml`: blobs present, `.md` matching what
    /// the parser derives (keeping the received date it recorded), and returns its index record.
    private func complete(id: MailMessageID, account: MailAccountID, emlURL: URL, fallbackReceived: Date?) throws -> IndexRecord {
        let eml = try Data(contentsOf: emlURL)
        let markdownURL = emlURL.deletingPathExtension().appendingPathExtension("md")
        let existingText = try? String(contentsOf: markdownURL, encoding: .utf8)
        let existing = existingText.flatMap { try? DerivedMarkdown.frontMatter(of: $0) }
        let message = try parser.parse(eml)
        let received = existing.flatMap { $0.id == id ? $0.received : nil }
            ?? fallbackReceived
            ?? message.date
            ?? Self.startOfMonth(folder: emlURL.deletingLastPathComponent())
            ?? Date(timeIntervalSince1970: 0)
        let derived = try derive(eml, parsed: message, id: id, account: account, received: received)
        try storeBlobs(derived.blobs)
        if existingText != derived.markdown {
            try AtomicWriter(faults: .none).write(Data(derived.markdown.utf8), to: markdownURL)
        }
        return IndexRecord(front: derived.front, message: derived.message, path: relativePath(of: emlURL),
                           attachmentText: attachmentText(for: derived.front.attachments))
    }

    // MARK: - Helpers

    private struct Derived {
        var message: ParsedMessage
        var front: MessageFrontMatter
        var markdown: String
        var blobs: [(hash: String, data: Data)]
    }

    private func derive(_ eml: Data, parsed message: ParsedMessage, id: MailMessageID, account: MailAccountID, received: Date) throws -> Derived {
        var blobs: [(hash: String, data: Data)] = []
        let attachments = message.attachments.map { attachment -> AttachmentReference in
            let hash = Hashing.sha256Hex(attachment.data)
            blobs.append((hash, attachment.data))
            return AttachmentReference(blob: hash, fileName: SafePath.displayFileName(attachment.fileName),
                                       mediaType: attachment.mediaType, size: attachment.data.count, inline: attachment.isInline,
                                       contentId: attachment.contentID)
        }
        let front = MessageFrontMatter(
            schema: DerivedMarkdown.schemaVersion, id: id, account: account, messageId: message.messageID,
            inReplyTo: message.inReplyTo, references: message.references, from: message.from, to: message.to, cc: message.cc,
            replyTo: message.replyTo, subject: message.subject, date: message.date, received: received,
            eml: "\(id.rawValue).eml", emlSha256: Hashing.sha256Hex(eml), emlSize: eml.count, attachments: attachments)
        return Derived(message: message, front: front, markdown: try DerivedMarkdown.render(front, message: message), blobs: blobs)
    }

    /// Writes each blob once: the name is the hash, so a blob that exists holds these bytes.
    private func storeBlobs(_ blobs: [(hash: String, data: Data)]) throws {
        for blob in blobs {
            let url = locations.blobsFolder.appendingPathComponent(blob.hash)
            if !FileManager.default.fileExists(atPath: url.path) { try writer.write(blob.data, to: url) }
        }
    }

    private func messageDirectory(account: String, date: Date) throws -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month], from: date)
        return locations.accountsFolder
            .appendingPathComponent(try SafePath.component(account), isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", parts.year ?? 1970), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month ?? 1), isDirectory: true)
    }

    /// The first instant of the month a `<yyyy>/<mm>` folder names: the received date of last
    /// resort for an `.eml` whose `.md` is gone and whose Date header is missing or unreadable.
    private static func startOfMonth(folder: URL) -> Date? {
        guard let month = Int(folder.lastPathComponent), let year = Int(folder.deletingLastPathComponent().lastPathComponent) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: 1))
    }

    private func url(of id: MailMessageID) throws -> URL {
        guard let path = try index.path(of: id), let url = safeFile(path) else { throw MailStoreError.messageNotFound(id.rawValue) }
        return url
    }

    private func relativePath(of url: URL) -> String {
        let root = locations.mailFolder.standardizedFileURL.pathComponents
        return url.standardizedFileURL.pathComponents.dropFirst(root.count).joined(separator: "/")
    }

    /// A relative path read back from the journal or the index, as a URL inside the mail folder.
    private func safeFile(_ relative: String) -> URL? {
        let components = relative.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { return nil }
        let url = components.reduce(locations.mailFolder) { $0.appendingPathComponent($1) }
        return SafePath.isContained(url, in: locations.mailFolder) ? url : nil
    }

    private func safeDirectory(_ relative: String) -> URL? { safeFile(relative) }

    func sortedContents(of folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func removePartials(in folder: URL, prefix: String = ".") throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(atPath: folder.path)
        where file.hasPrefix(prefix) && file.hasSuffix(AtomicWriter.partialSuffix) {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
    }

    func mapping(for account: String) throws -> RemoteMapping {
        if let mapping = mappings[account] { return mapping }
        let mapping = try RemoteMapping(url: locations.stateFolder(account).appendingPathComponent("sync.sqlite"))
        mappings[account] = mapping
        return mapping
    }

    private static func openIndex(at url: URL) throws -> MailIndex {
        do {
            return try MailIndex(url: url)
        } catch MailStoreError.sqlite {
            // The index is a cache of the folder. A damaged file is replaced, then rebuilt.
            for suffix in ["", "-wal", "-shm"] {
                let file = URL(fileURLWithPath: url.path + suffix)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
            return try MailIndex(url: url)
        }
    }

    /// Reads `layout.json`, writes it on a new folder, and refuses a folder from a newer app.
    /// Migration hook: when the layout changes, the step from each older version goes here.
    private static func checkLayout(_ locations: StoreLocations) throws {
        let url = locations.layoutURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            try AtomicWriter(faults: .none).write(JSONCoding.prettyEncoder.encode(Layout(layoutVersion: layoutVersion)), to: url)
            return
        }
        let layout = try JSONCoding.decoder.decode(Layout.self, from: Data(contentsOf: url))
        guard layout.layoutVersion <= layoutVersion else { throw MailStoreError.unsupportedLayoutVersion(layout.layoutVersion) }
        // layout.layoutVersion < layoutVersion: no older layouts exist yet (version 1).
    }
}

private struct Layout: Codable {
    var layoutVersion: Int
}

/// A write in progress, in `<device folder>/state/journal/<id>.json`.
private struct JournalEntry: Codable {
    var id: MailMessageID
    var account: MailAccountID
    /// The message's folder, relative to the mail folder.
    var directory: String
    var remote: RemoteLocation?
    var received: Date
}

enum JSONCoding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var prettyEncoder: JSONEncoder {
        let encoder = encoder
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
