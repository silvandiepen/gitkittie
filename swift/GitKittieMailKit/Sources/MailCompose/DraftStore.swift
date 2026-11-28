import CryptoKit
import Foundation
import MailMIME
import MailStore

/// What a save did.
public enum DraftSaveResult: Sendable, Equatable {
    /// Saved as the next revision of the same draft.
    case saved(ComposeDraft)
    /// Someone else (another window, or another device through a synced folder) saved this
    /// draft since this edit started. Nothing was overwritten: this edit became a new draft,
    /// a conflict copy, and both are kept.
    case conflict(copy: ComposeDraft)
    /// Nothing changed since the last revision; nothing was written.
    case unchanged(ComposeDraft)

    public var draft: ComposeDraft {
        switch self {
        case .saved(let d), .conflict(let d), .unchanged(let d): d
        }
    }
}

/// Drafts in the mail folder (Architecture.md, Storage and identity: `Mail/drafts/`):
///
///     Mail/drafts/<draft-id>/draft.json            the current revision
///     Mail/drafts/<draft-id>/versions/<n>.json     earlier revisions (the last ``keptVersions``)
///     Mail/drafts/<draft-id>/attachments/<sha256>  attached files, by content
///
/// Every write is atomic and fsynced (``DurableFile``), so a crash leaves the last saved
/// revision whole. A save names the revision it started from; if the draft moved on since,
/// the save becomes a conflict copy instead of overwriting (Architecture.md, Multi-device sync:
/// preserve conflicting drafts). Files a sync tool left beside `draft.json` (iCloud Drive's
/// "draft 2.json") are adopted as conflict copies too.
public actor DraftStore {
    public nonisolated let folder: URL
    public nonisolated let deviceID: String
    /// Non-nil when the drafts folder is only read (GKM-104, MAIL-135): why, in words for the
    /// person. Saving, attaching and deleting then throw ``MailStoreError/readOnly(_:)``, and
    /// listing does not adopt a sync tool's conflict files, which would write.
    public nonisolated let readOnlyReason: String?
    public static let keptVersions = 20
    /// Per attachment. The composer limits the whole message (``MessageComposer/maximumSize``).
    public static let maximumAttachmentSize = 25 * 1024 * 1024

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(folder: URL, deviceID: String, readOnlyReason: String? = nil) {
        self.folder = folder
        self.deviceID = deviceID
        self.readOnlyReason = readOnlyReason
    }

    public init(locations: StoreLocations, readOnlyReason: String? = nil) throws {
        self.init(folder: locations.draftsFolder, deviceID: try locations.deviceIdentifier(), readOnlyReason: readOnlyReason)
    }

    private func requireWritable() throws {
        if let readOnlyReason { throw MailStoreError.readOnly(readOnlyReason) }
    }

    // MARK: - Reading

    /// Every draft, newest first. Adopts sync-conflict files on the way; skips a draft whose
    /// file cannot be read (it stays on disk untouched).
    public func drafts() throws -> [ComposeDraft] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: folder.path) else { return [] }
        var drafts: [ComposeDraft] = []
        for name in try fileManager.contentsOfDirectory(atPath: folder.path) {
            guard let id = DraftID(name), name == id.rawValue else { continue }
            if readOnlyReason == nil { try adoptSyncConflicts(of: id) }
            if let draft = try? read(directory(of: id).appendingPathComponent("draft.json")) {
                drafts.append(draft)
            }
        }
        for name in try fileManager.contentsOfDirectory(atPath: folder.path) {
            guard let id = DraftID(name), name == id.rawValue, !drafts.contains(where: { $0.id == id }) else { continue }
            if let draft = try? read(directory(of: id).appendingPathComponent("draft.json")) { drafts.append(draft) }
        }
        return drafts.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }

    public func draft(_ id: DraftID) throws -> ComposeDraft? {
        let url = directory(of: id).appendingPathComponent("draft.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try read(url)
    }

    /// Earlier revisions, newest first.
    public func versions(of id: DraftID) throws -> [ComposeDraft] {
        let versions = directory(of: id).appendingPathComponent("versions", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: versions.path) else { return [] }
        return names.compactMap { name -> ComposeDraft? in
            guard name.hasSuffix(".json"), Int(name.dropLast(5)) != nil else { return nil }
            return try? read(versions.appendingPathComponent(name))
        }.sorted { $0.revision > $1.revision }
    }

    // MARK: - Writing

    /// Saves `draft` as the revision after `draft.revision`, unless the stored draft has moved
    /// past it (then a conflict copy) or nothing changed.
    public func save(_ draft: ComposeDraft, now: Date = Date()) throws -> DraftSaveResult {
        try requireWritable()
        let directory = directory(of: draft.id)
        let headURL = directory.appendingPathComponent("draft.json")
        let current = FileManager.default.fileExists(atPath: headURL.path) ? try read(headURL) : nil

        if let current {
            if current.revision != draft.revision {
                // Not ours to overwrite. Keep this edit as a draft of its own.
                if current.content == draft.content { return .unchanged(current) }
                var copy = draft
                copy.id = DraftID()
                copy.conflictOf = draft.id
                copy.revision = 0
                copy.createdAt = now
                try copyAttachments(copy.attachments, from: draft.id, to: copy.id)
                return .conflict(copy: try write(copy, previous: nil, now: now))
            }
            if current.content == draft.content { return .unchanged(current) }
        }
        return .saved(try write(draft, previous: current, now: now))
    }

    /// Adds a file to the draft's attachment folder and returns the reference to put on it.
    public func addAttachment(_ data: Data, filename: String, mimeType: String, to id: DraftID) throws -> DraftAttachment {
        try requireWritable()
        guard data.count <= Self.maximumAttachmentSize else {
            throw ComposeError.tooLarge(bytes: data.count, limit: Self.maximumAttachmentSize)
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let url = directory(of: id).appendingPathComponent("attachments", isDirectory: true).appendingPathComponent(hash)
        if !FileManager.default.fileExists(atPath: url.path) { try DurableFile.write(data, to: url) }
        return DraftAttachment(filename: MIMEPart.safeFilename(filename), mimeType: Self.cleanMIMEType(mimeType),
                               size: data.count, sha256: hash)
    }

    /// The draft's attachments, ready for the composer. Each file is checked against its hash.
    public func outgoingAttachments(of draft: ComposeDraft) throws -> [OutgoingAttachment] {
        try draft.attachments.map { attachment in
            guard attachment.sha256.count == 64, attachment.sha256.allSatisfy(\.isHexDigit) else {
                throw ComposeError.missingAttachment(attachment.filename)
            }
            let url = directory(of: draft.id).appendingPathComponent("attachments/\(attachment.sha256)")
            guard let data = try? Data(contentsOf: url),
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == attachment.sha256 else {
                throw ComposeError.missingAttachment(attachment.filename)
            }
            return OutgoingAttachment(filename: attachment.filename, mimeType: attachment.mimeType, data: data)
        }
    }

    /// Removes a draft and everything with it: after it was queued for sending, or discarded.
    public func delete(_ id: DraftID) throws {
        try requireWritable()
        let directory = directory(of: id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
        try DurableFile.syncDirectory(folder)
    }

    // MARK: - Internals

    private func write(_ draft: ComposeDraft, previous: ComposeDraft?, now: Date) throws -> ComposeDraft {
        let directory = directory(of: draft.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try DurableFile.removePartials(in: directory)
        if let previous {
            let versions = directory.appendingPathComponent("versions", isDirectory: true)
            let url = versions.appendingPathComponent("\(previous.revision).json")
            if !FileManager.default.fileExists(atPath: url.path) { try DurableFile.write(encoder.encode(previous), to: url) }
            try prune(versions)
        }
        var next = draft
        next.revision = (previous?.revision ?? draft.revision) + 1
        // Whole seconds: what ISO 8601 in the file keeps, so a draft reads back equal.
        next.updatedAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        next.createdAt = Date(timeIntervalSince1970: next.createdAt.timeIntervalSince1970.rounded(.down))
        next.savedBy = deviceID
        try DurableFile.write(encoder.encode(next), to: directory.appendingPathComponent("draft.json"))
        return next
    }

    private func prune(_ versions: URL) throws {
        let numbered = ((try? FileManager.default.contentsOfDirectory(atPath: versions.path)) ?? [])
            .compactMap { name -> Int? in name.hasSuffix(".json") ? Int(name.dropLast(5)) : nil }
            .sorted(by: >)
        for revision in numbered.dropFirst(Self.keptVersions) {
            try FileManager.default.removeItem(at: versions.appendingPathComponent("\(revision).json"))
        }
    }

    /// Any other `.json` beside `draft.json` came from a sync tool resolving a clash. Each one
    /// becomes a draft of its own, so no edit is lost and none silently wins.
    private func adoptSyncConflicts(of id: DraftID) throws {
        let directory = directory(of: id)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".json") && name != "draft.json" && !name.hasPrefix(".") {
            let url = directory.appendingPathComponent(name)
            guard var adopted = try? read(url) else { continue }
            adopted.id = DraftID()
            adopted.conflictOf = id
            adopted.revision = 0
            try copyAttachments(adopted.attachments, from: id, to: adopted.id)
            _ = try write(adopted, previous: nil, now: adopted.updatedAt)
            try FileManager.default.removeItem(at: url)
        }
    }

    private func copyAttachments(_ attachments: [DraftAttachment], from source: DraftID, to destination: DraftID) throws {
        for attachment in attachments where attachment.sha256.count == 64 && attachment.sha256.allSatisfy(\.isHexDigit) {
            let from = directory(of: source).appendingPathComponent("attachments/\(attachment.sha256)")
            let to = directory(of: destination).appendingPathComponent("attachments/\(attachment.sha256)")
            guard let data = try? Data(contentsOf: from), !FileManager.default.fileExists(atPath: to.path) else { continue }
            try DurableFile.write(data, to: to)
        }
    }

    private func read(_ url: URL) throws -> ComposeDraft {
        try decoder.decode(ComposeDraft.self, from: Data(contentsOf: url))
    }

    /// `DraftID` only holds a lowercase UUID, so this never leaves the drafts folder.
    private func directory(of id: DraftID) -> URL {
        folder.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    static func cleanMIMEType(_ value: String) -> String {
        ReplyBuilder.safeMIMEType(value)
    }
}
