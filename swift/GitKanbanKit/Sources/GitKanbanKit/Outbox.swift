import CryptoKit
import Foundation
import GitKittieKit
import GitPontCore

// Writes to a hosted provider go through an outbox.
//
// A write is saved to disk first and sent afterwards, in order, in the background. So
// creating or editing a card never waits for the network, works with no connection at
// all, and survives the app (or the share extension) being closed mid-send: whatever is
// still in the outbox is sent the next time anything flushes it.
//
// `OutboxSource` is the piece the rest of the app sees. It wraps the real source: writes
// become outbox entries, and reads are overlaid with the entries not sent yet, so a card
// you just made is on the board straight away. Reads that fail for lack of a connection
// fall back to the last copy read (`ReadCache`), which is what makes the board usable
// offline.

/// One write waiting to be sent, or one that was refused.
public struct OutboxOperation: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case write, delete }
    public enum State: String, Codable, Sendable { case pending, sending, failed }

    public var id: String
    /// Which added repo the write belongs to (`AddedRepo.id`).
    public var repoKey: String
    public var kind: Kind
    public var path: String
    /// The commit message, which doubles as the line shown in the activity list.
    public var message: String
    public var createdAt: Date
    public var state: State
    /// Why it has not gone out: the refusal, or that there is no connection.
    public var note: String?
    public var attempts: Int
    /// For a review request: what the reviewer did. Sent by applying it again onto the
    /// file as it is on the server then, not by sending the copy in the blob (`ReviewEdits.swift`).
    public var review: [ReviewEdit]?

    /// The name of the file holding this write's bytes, next to the index.
    var blobName: String { "\(id).blob" }

    /// Which file of which repo it is for.
    var fileKey: String { "\(repoKey)|\(path)" }

    /// A write to a review request, sent by merging rather than by replacing the file. Writes
    /// queued before the outbox kept edits carry only the whole file; their edits are read
    /// back from that copy (`Review.edits(inSnapshot:)`).
    public var mergesReview: Bool {
        kind == .write && (review != nil || path.split(separator: "/").last.map(String.init) == Review.fileName)
    }
}

/// A write that went out, kept for the activity list.
public struct OutboxReceipt: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var message: String
    public var path: String
    public var sentAt: Date
    /// What happened to it on the way, when that is worth saying (a review edit the server
    /// already had a newer answer for).
    public var note: String?
}

/// Why the outbox could not do what it was asked.
public enum OutboxError: LocalizedError, Equatable {
    /// The change could not be stored on this device, so it was not queued at all.
    case notSaved(path: String, reason: String)
    /// The queue's index could not be read or written.
    case index(reason: String)
    /// A queued write whose content is not on this device.
    case contentMissing(path: String)

    public var errorDescription: String? {
        switch self {
        case .notSaved(let path, let reason):
            return "Not saved: \(path) could not be stored on this device (\(reason)). Free up some space and make the change again."
        case .index(let reason):
            return "The list of changes waiting to be sent could not be updated (\(reason))."
        case .contentMissing(let path):
            return "Nothing was stored on this device for this change to \(path) (the disk was probably full when it was made), so it cannot be sent. Discard it and make the change again."
        }
    }
}

/// The saved queue of writes. Shared on disk by the app and its extensions, so every
/// change re-reads the index under a file lock first.
public actor Outbox {
    private let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("outbox.json") }
    private var receiptsURL: URL { directory.appendingPathComponent("sent.json") }
    private var lockURL: URL { directory.appendingPathComponent("outbox.lock") }
    private var flushLockURL: URL { directory.appendingPathComponent("flush.lock") }

    /// The index as last read, with the file's modification date it was read at.
    private var cached: [OutboxOperation] = []
    private var cachedStamp: Date?
    private var isFlushing = false

    public init(directory: URL) {
        self.directory = directory
        // A folder that cannot be made here makes the first write throw, with the reason.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Reading

    /// The index on disk. No file is an empty queue; a file that cannot be read or decoded
    /// is an error, never an empty queue: the next change would otherwise write over every
    /// change still in it.
    private func readIndex() throws -> [OutboxOperation] {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: indexURL.path))?[.modificationDate] as? Date
        guard let stamp else {
            guard !FileManager.default.fileExists(atPath: indexURL.path) else {
                throw OutboxError.index(reason: "the list cannot be read")
            }
            cached = []
            cachedStamp = nil
            return []
        }
        if stamp != cachedStamp {
            do {
                cached = try JSONDecoder().decode([OutboxOperation].self, from: Data(contentsOf: indexURL))
            } catch {
                throw OutboxError.index(reason: error.localizedDescription)
            }
            cachedStamp = stamp
        }
        return cached
    }

    /// Everything waiting or refused, oldest first. When the index cannot be read, the
    /// last list read: the writes are still on disk and nothing is changed until it reads.
    public func operations() -> [OutboxOperation] {
        (try? readIndex()) ?? cached
    }

    /// Writes that went out recently. Only for the activity list: when the file is gone or
    /// unreadable there is nothing to lose, so it reads as empty.
    public func receipts() -> [OutboxReceipt] {
        (try? JSONDecoder().decode([OutboxReceipt].self, from: Data(contentsOf: receiptsURL))) ?? []
    }

    /// The bytes a write carries; `nil` when there are none on disk.
    public func data(for operation: OutboxOperation) -> Data? {
        let url = directory.appendingPathComponent(operation.blobName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// What a write changes in a review request: its own edits, or for one queued before
    /// edits were kept, those read back from its copy of the file. `nil` when it is not a
    /// review write, or its copy is not on this device.
    public func reviewEdits(for operation: OutboxOperation) -> [ReviewEdit]? {
        guard operation.mergesReview else { return nil }
        if let edits = operation.review { return edits }
        guard let data = data(for: operation), let text = String(data: data, encoding: .utf8) else { return nil }
        return Review.edits(inSnapshot: text)
    }

    // MARK: Changing

    /// Run `change` on the index while holding the cross-process lock, and write it back.
    /// Throws, having changed nothing, when the index cannot be read or written.
    private func mutate(_ change: (inout [OutboxOperation]) -> Void) throws {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        if descriptor >= 0 { flock(descriptor, LOCK_EX) }
        defer { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
        cachedStamp = nil
        var current = try readIndex()
        change(&current)
        do {
            try JSONEncoder().encode(current).write(to: indexURL, options: .atomic)
        } catch {
            cachedStamp = nil
            throw OutboxError.index(reason: error.localizedDescription)
        }
        cached = current
        cachedStamp = (try? FileManager.default.attributesOfItem(atPath: indexURL.path))?[.modificationDate] as? Date
    }

    /// Queue a write. The content is stored first and the write is listed only once it
    /// is: a write is never queued without what it carries. Throws `notSaved` when either
    /// cannot be stored, and then nothing is queued.
    @discardableResult
    func enqueue(
        repoKey: String, kind: OutboxOperation.Kind, path: String, message: String, data: Data?, review: [ReviewEdit]? = nil
    ) throws -> OutboxOperation {
        let operation = OutboxOperation(
            id: UUID().uuidString, repoKey: repoKey, kind: kind, path: path, message: message,
            createdAt: Date(), state: .pending, note: nil, attempts: 0, review: review)
        let blob = directory.appendingPathComponent(operation.blobName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data { try data.write(to: blob, options: .atomic) }
        } catch {
            throw OutboxError.notSaved(path: path, reason: Self.reason(error))
        }
        do {
            try mutate { $0.append(operation) }
        } catch {
            try? FileManager.default.removeItem(at: blob)
            throw OutboxError.notSaved(path: path, reason: Self.reason(error))
        }
        return operation
    }

    /// Give a refused write another go.
    public func retry(_ id: String) throws {
        try mutate { operations in
            if let index = operations.firstIndex(where: { $0.id == id }) {
                operations[index].state = .pending
                operations[index].note = nil
            }
        }
    }

    /// Drop a write without sending it. Its content goes only once it is off the list.
    public func discard(_ id: String) throws {
        try mutate { $0.removeAll { $0.id == id } }
        // What is left of a blob that cannot be removed is an unused file, nothing more.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).blob"))
    }

    /// Writes that went out: off the list, and into the receipts.
    private func finish(_ operations: [OutboxOperation], note: String?) throws {
        let ids = Set(operations.map(\.id))
        try mutate { $0.removeAll { ids.contains($0.id) } }
        for id in ids { try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).blob")) }
        var sent = receipts()
        for (offset, operation) in operations.enumerated() {
            sent.insert(OutboxReceipt(id: operation.id, message: operation.message, path: operation.path, sentAt: Date(),
                                      note: offset == operations.count - 1 ? note : nil), at: 0)
        }
        // The receipts are a history for the activity list: the writes they describe have
        // gone out, so a history that cannot be saved loses nothing.
        if let data = try? JSONEncoder().encode(Array(sent.prefix(40))) { try? data.write(to: receiptsURL, options: .atomic) }
    }

    private func update(_ ids: Set<String>, _ change: (inout OutboxOperation) -> Void) throws {
        try mutate { operations in
            for index in operations.indices where ids.contains(operations[index].id) { change(&operations[index]) }
        }
    }

    // MARK: Sending

    /// Send what is waiting, oldest first. One flush runs at a time, across processes.
    /// A connection failure stops the run and leaves everything waiting; a refusal marks
    /// that write failed and holds back later writes to the same file. Writes to a review
    /// request are the exception: they are merged onto the server's copy, so they are sent
    /// together (folded) and never wait behind a refused one. When the list itself cannot be
    /// updated the run stops, leaving every write where it is.
    /// Returns how many writes went out.
    @discardableResult
    func flush(
        resolve: @Sendable (String) async -> (any BoardWritable)?,
        changed: @Sendable () async -> Void
    ) async -> Int {
        guard !isFlushing else { return 0 }
        let descriptor = open(flushLockURL.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            return 0
        }
        isFlushing = true
        defer { isFlushing = false; flock(descriptor, LOCK_UN); close(descriptor) }

        // Anything still marked as sending was cut off by a process ending: send it again.
        do {
            try mutate { operations in
                for index in operations.indices where operations[index].state == .sending { operations[index].state = .pending }
            }
        } catch {
            return 0
        }
        var sent = 0
        var skipped: Set<String> = []
        do {
            while true {
                let current = operations()
                let blocked = Set(current.filter { $0.state == .failed && !$0.mergesReview }.map(\.fileKey))
                guard let next = current.first(where: {
                    $0.state == .pending && !skipped.contains($0.id) && !blocked.contains($0.fileKey)
                }) else { break }
                guard let source = await resolve(next.repoKey) else {
                    try update([next.id]) { $0.note = "Waiting until you are signed in." }
                    skipped.insert(next.id)
                    continue
                }
                // Every waiting write to the same review request goes out as one.
                var batch = next.mergesReview
                    ? current.filter { $0.state == .pending && $0.fileKey == next.fileKey && $0.mergesReview && !skipped.contains($0.id) }
                    : [next]
                var edits: [ReviewEdit] = []
                if next.mergesReview {
                    let unreadable = batch.filter { reviewEdits(for: $0) == nil }
                    if !unreadable.isEmpty {
                        try update(Set(unreadable.map(\.id))) {
                            $0.state = .failed
                            $0.attempts += 1
                            $0.note = OutboxError.contentMissing(path: $0.path).errorDescription
                        }
                        batch.removeAll { item in unreadable.contains { $0.id == item.id } }
                        await changed()
                        if batch.isEmpty { continue }
                    }
                    edits = batch.flatMap { reviewEdits(for: $0) ?? [] }
                }
                let ids = Set(batch.map(\.id))
                try update(ids) { $0.state = .sending; $0.note = nil }
                await changed()
                do {
                    var note: String?
                    if next.mergesReview {
                        note = Self.receiptNote(try await Self.sendReview(path: next.path, edits: edits, message: next.message, to: source))
                    } else {
                        switch next.kind {
                        case .write:
                            guard let data = data(for: next) else { throw OutboxError.contentMissing(path: next.path) }
                            try await source.writeData(path: next.path, data: data, message: next.message)
                        case .delete:
                            try await source.delete(path: next.path, message: next.message)
                        }
                    }
                    try finish(batch, note: note)
                    sent += batch.count
                    await changed()
                } catch let error as OutboxError {
                    guard case .contentMissing = error else { throw error }
                    try update(ids) { $0.state = .failed; $0.attempts += 1; $0.note = error.errorDescription }
                    await changed()
                } catch where Outbox.isConnectivity(error) {
                    try update(ids) { $0.state = .pending; $0.note = "Waiting for a connection." }
                    await changed()
                    break
                } catch {
                    try update(ids) {
                        $0.state = .failed
                        $0.attempts += 1
                        $0.note = Self.refusal(error, for: $0)
                    }
                    await changed()
                }
            }
        } catch {
            // The list could not be updated (the disk is full, say). Everything stays queued
            // as it is on disk and goes out on a later run.
        }
        await changed()
        return sent
    }

    /// Apply review edits onto the request as it is on the server now and write the result,
    /// compare-and-swap where the source can: an edit made by someone else in between is
    /// read again and the edits re-applied, never overwritten. Nothing is written when the
    /// server already has everything.
    static func sendReview(path: String, edits: [ReviewEdit], message: String, to source: any BoardWritable) async throws -> ReviewMerge {
        if let versioned = versioned(source) {
            var attempt = 0
            while true {
                let (text, version) = try await versioned.readVersioned(path)
                let merge = try Review.merge(text, edits: edits)
                guard !merge.applied.isEmpty else { return merge }
                do {
                    try await versioned.write(path: path, text: merge.text, ifVersion: version, message: message)
                    return merge
                } catch is SourceConflictError where attempt < 3 {
                    attempt += 1
                }
            }
        }
        let merge = try Review.merge(try await source.readText(path), edits: edits)
        if !merge.applied.isEmpty { try await source.write(path: path, text: merge.text, message: message) }
        return merge
    }

    /// The compare-and-swap side of a source, also through the bucket layer: a review
    /// request is text and always lives in the repository itself.
    static func versioned(_ source: any BoardWritable) -> (any VersionedBoardSource)? {
        if let versioned = source as? any VersionedBoardSource { return versioned }
        if let bucket = source as? BucketSource { return bucket.base as? any VersionedBoardSource }
        return nil
    }

    static func receiptNote(_ merge: ReviewMerge) -> String? {
        var parts: [String] = []
        if merge.applied.isEmpty { parts.append("The server already had these changes.") }
        if !merge.superseded.isEmpty {
            parts.append("Left out because the server has something newer: " + merge.superseded.map(\.summary).joined(separator: ", ") + ".")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// What a refused write says in the activity list, with what can be done about it.
    static func refusal(_ error: Error, for operation: OutboxOperation) -> String {
        if (error as? BoardSourceError)?.isConflict == true || error is SourceConflictError {
            return "\(operation.path) changed on the server while this change was on its way. "
                + "Retry sends your version and replaces what is on the server; Discard keeps the server's. "
                + "Use Show What It Was to copy your version first."
        }
        return error.localizedDescription
    }

    private static func reason(_ error: Error) -> String {
        if let error = error as? OutboxError, case .index(let reason) = error { return reason }
        let code = (error as NSError).code
        if (error as NSError).domain == NSCocoaErrorDomain, code == NSFileWriteOutOfSpaceError { return "the disk is full" }
        if let posix = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain, posix.code == Int(ENOSPC) {
            return "the disk is full"
        }
        return error.localizedDescription
    }

    /// Whether an error means "try again later" rather than "this was refused".
    static func isConnectivity(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
                    .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed]
                .contains(error.code)
        }
        if let error = error as? GitPontError {
            switch error {
            case .rateLimited, .providerUnavailable: return true
            default: return false
            }
        }
        return false
    }
}

/// The last copy of what was read from a source, for when there is no connection.
struct ReadCache: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest)
    }

    /// A copy for reading offline. It holds nothing that is not on the server, so a copy
    /// that cannot be stored (a full disk) only means an older copy, or none, offline.
    func store(_ data: Data, for key: String) { try? data.write(to: url(key), options: .atomic) }
    func data(for key: String) -> Data? { try? Data(contentsOf: url(key)) }

    private struct Entry: Codable { let name: String; let path: String; let isDirectory: Bool }

    func store(_ entries: [BoardFileEntry], for key: String) {
        let raw = entries.map { Entry(name: $0.name, path: $0.path, isDirectory: $0.kind == .directory) }
        if let data = try? JSONEncoder().encode(raw) { store(data, for: key) }
    }

    func entries(for key: String) -> [BoardFileEntry]? {
        guard let data = data(for: key), let raw = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        return raw.map { BoardFileEntry(name: $0.name, path: $0.path, kind: $0.isDirectory ? .directory : .file) }
    }
}

/// A source whose writes go through the outbox and whose reads include what is still in it.
struct OutboxSource: BatchWritable, BulkTextSource, WebLinkingSource {
    let base: any BoardWritable
    let outbox: Outbox
    let repoKey: String
    /// The branch the repo is read from, for telling which pushes concern it.
    var branch = ""
    let cache: ReadCache
    /// Called after a write is saved, to get a flush going.
    let saved: @Sendable () -> Void

    /// The unsent write that decides what each path holds: the last one per path.
    private func waiting() async -> [OutboxOperation] {
        var result: [OutboxOperation] = []
        for operation in await outbox.operations() where operation.repoKey == repoKey {
            result.removeAll { $0.path == operation.path }
            result.append(operation)
        }
        return result
    }

    func list(_ directory: String) async throws -> [BoardFileEntry] {
        let prefix = directory.isEmpty ? "" : directory + "/"
        let inside = await waiting().filter { $0.path.hasPrefix(prefix) }
        let key = "list|\(repoKey)|\(directory)"
        var entries: [BoardFileEntry]
        do {
            entries = try await base.list(directory)
            cache.store(entries, for: key)
        } catch {
            // No connection: the last listing. A folder that only exists in the outbox so
            // far (a new card's attachments) has no listing at all yet.
            if Outbox.isConnectivity(error), let known = cache.entries(for: key) {
                entries = known
            } else if inside.contains(where: { $0.kind == .write }) {
                entries = []
            } else {
                throw error
            }
        }
        for item in inside {
            let rest = String(item.path.dropFirst(prefix.count))
            guard !rest.isEmpty else { continue }
            if let slash = rest.firstIndex(of: "/") {
                let name = String(rest[..<slash])
                if item.kind == .write, !entries.contains(where: { $0.name == name }) {
                    entries.append(BoardFileEntry(name: name, path: prefix + name, kind: .directory))
                }
            } else {
                entries.removeAll { $0.name == rest }
                if item.kind == .write { entries.append(BoardFileEntry(name: rest, path: item.path, kind: .file)) }
            }
        }
        return entries
    }

    /// The unsent content of a path, if a write (or a delete) for it is waiting.
    ///
    /// For a review request the server's copy is read and what is queued applied onto it,
    /// so an answer the reviewer gave on another device, or a round the agent added, shows
    /// with the queued edits instead of being hidden behind an older copy. Without a server
    /// copy (no connection and none kept) the last queued copy is used.
    private func unsent(_ path: String) async throws -> Data? {
        let queued = await outbox.operations().filter { $0.repoKey == repoKey && $0.path == path }
        guard let item = queued.last else { return nil }
        if queued.allSatisfy(\.mergesReview) {
            var edits: [ReviewEdit] = []
            for operation in queued { edits += await outbox.reviewEdits(for: operation) ?? [] }
            do {
                let server = try await baseText(path)
                return Data(try Review.merge(server, edits: edits).text.utf8)
            } catch {
                // No server copy to apply them to: the last copy queued, when there is one.
                for operation in queued.reversed() {
                    if let data = await outbox.data(for: operation) { return data }
                }
                throw error
            }
        }
        guard item.kind == .write else { throw BoardSourceError(message: "\(path) was deleted.") }
        // A write that has no content on this device changes nothing until it is discarded.
        guard let data = await outbox.data(for: item) else { return nil }
        return data
    }

    /// The server's text of a path, or the last copy read when there is no connection.
    private func baseText(_ path: String) async throws -> String {
        let key = "text|\(repoKey)|\(path)"
        do {
            let text = try await base.readText(path)
            cache.store(Data(text.utf8), for: key)
            return text
        } catch where Outbox.isConnectivity(error) {
            guard let data = cache.data(for: key), let text = String(data: data, encoding: .utf8) else { throw error }
            return text
        }
    }

    func readData(_ path: String) async throws -> Data {
        if let data = try await unsent(path) { return data }
        return try await base.readData(path)
    }

    func readText(_ path: String) async throws -> String {
        if let data = try await unsent(path) {
            guard let text = String(data: data, encoding: .utf8) else { throw BoardSourceError(message: "\(path) is not a text file.") }
            return text
        }
        return try await baseText(path)
    }

    /// The folder's texts in one round trip when the provider can, kept for offline use.
    /// Paths with an unsent write are left out, so they are read through `readText`.
    func readTexts(in directory: String) async -> [String: String]? {
        guard let bulk = base as? any BulkTextSource, var texts = await bulk.readTexts(in: directory) else { return nil }
        let prefix = directory.isEmpty ? "" : directory + "/"
        for (name, text) in texts { cache.store(Data(text.utf8), for: "text|\(repoKey)|\(prefix)\(name)") }
        for item in await waiting() where item.path.hasPrefix(prefix) {
            texts[String(item.path.dropFirst(prefix.count))] = nil
        }
        return texts
    }

    func webURL(forPath path: String) -> URL? { (base as? any WebLinkingSource)?.webURL(forPath: path) }

    /// Several files in one commit, sent now and not queued: a queue entry is one file.
    /// False when the provider cannot, or when one of the files still has an unsent
    /// change that would overwrite this one later; the caller then writes them singly.
    func writeTexts(_ texts: [String: String], message: String) async throws -> Bool {
        guard let batch = base as? any BatchWritable else { return false }
        for item in await waiting() where texts[item.path] != nil { return false }
        guard try await batch.writeTexts(texts, message: message) else { return false }
        for (path, text) in texts { cache.store(Data(text.utf8), for: "text|\(repoKey)|\(path)") }
        return true
    }

    func write(path: String, text: String, message: String) async throws {
        try await writeData(path: path, data: Data(text.utf8), message: message)
    }

    func writeData(path: String, data: Data, message: String) async throws {
        try await outbox.enqueue(repoKey: repoKey, kind: .write, path: path, message: message, data: data)
        saved()
    }

    func delete(path: String, message: String) async throws {
        try await outbox.enqueue(repoKey: repoKey, kind: .delete, path: path, message: message, data: nil)
        saved()
    }
}

extension OutboxSource: ReviewEditingSource {
    /// Queue a reviewer's change to a review request: the edits, which are what is sent,
    /// and the file as it looks with them, which is what reads show until then.
    func writeReview(path: String, text: String, edits: [ReviewEdit], message: String) async throws {
        try await outbox.enqueue(repoKey: repoKey, kind: .write, path: path, message: message, data: Data(text.utf8), review: edits)
        saved()
    }
}

/// A source that keeps a reviewer's edits apart from the file they produce, so they can
/// be applied again onto a newer copy of it (the outbox).
protocol ReviewEditingSource: BoardWritable {
    func writeReview(path: String, text: String, edits: [ReviewEdit], message: String) async throws
}
