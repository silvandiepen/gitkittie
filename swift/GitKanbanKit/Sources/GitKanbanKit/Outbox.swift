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

    /// The name of the file holding this write's bytes, next to the index.
    var blobName: String { "\(id).blob" }
}

/// A write that went out, kept for the activity list.
public struct OutboxReceipt: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var message: String
    public var path: String
    public var sentAt: Date
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
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Reading

    /// Everything waiting or refused, oldest first.
    public func operations() -> [OutboxOperation] {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: indexURL.path))?[.modificationDate] as? Date
        if stamp != cachedStamp || stamp == nil {
            cached = (try? JSONDecoder().decode([OutboxOperation].self, from: Data(contentsOf: indexURL))) ?? []
            cachedStamp = stamp
        }
        return cached
    }

    public func receipts() -> [OutboxReceipt] {
        (try? JSONDecoder().decode([OutboxReceipt].self, from: Data(contentsOf: receiptsURL))) ?? []
    }

    func data(for operation: OutboxOperation) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(operation.blobName))
    }

    // MARK: Changing

    /// Run `change` on the index while holding the cross-process lock.
    private func mutate(_ change: (inout [OutboxOperation]) -> Void) {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        if descriptor >= 0 { flock(descriptor, LOCK_EX) }
        defer { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
        cachedStamp = nil
        var current = operations()
        change(&current)
        if let data = try? JSONEncoder().encode(current) { try? data.write(to: indexURL, options: .atomic) }
        cached = current
        cachedStamp = (try? FileManager.default.attributesOfItem(atPath: indexURL.path))?[.modificationDate] as? Date
    }

    @discardableResult
    func enqueue(repoKey: String, kind: OutboxOperation.Kind, path: String, message: String, data: Data?) -> OutboxOperation {
        let operation = OutboxOperation(
            id: UUID().uuidString, repoKey: repoKey, kind: kind, path: path, message: message,
            createdAt: Date(), state: .pending, note: nil, attempts: 0)
        if let data { try? data.write(to: directory.appendingPathComponent(operation.blobName), options: .atomic) }
        mutate { $0.append(operation) }
        return operation
    }

    /// Give a refused write another go.
    public func retry(_ id: String) {
        mutate { operations in
            if let index = operations.firstIndex(where: { $0.id == id }) {
                operations[index].state = .pending
                operations[index].note = nil
            }
        }
    }

    /// Drop a write without sending it.
    public func discard(_ id: String) {
        mutate { $0.removeAll { $0.id == id } }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).blob"))
    }

    private func finish(_ operation: OutboxOperation) {
        discard(operation.id)
        var sent = receipts()
        sent.insert(OutboxReceipt(id: operation.id, message: operation.message, path: operation.path, sentAt: Date()), at: 0)
        if let data = try? JSONEncoder().encode(Array(sent.prefix(40))) { try? data.write(to: receiptsURL, options: .atomic) }
    }

    private func update(_ id: String, _ change: (inout OutboxOperation) -> Void) {
        mutate { operations in
            if let index = operations.firstIndex(where: { $0.id == id }) { change(&operations[index]) }
        }
    }

    // MARK: Sending

    /// Send what is waiting, oldest first. One flush runs at a time, across processes.
    /// A connection failure stops the run and leaves everything waiting; a refusal marks
    /// that one write failed and holds back later writes to the same file.
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
        mutate { operations in
            for index in operations.indices where operations[index].state == .sending { operations[index].state = .pending }
        }
        var sent = 0
        var skipped: Set<String> = []
        while true {
            let blockedPaths = Set(operations().filter { $0.state == .failed }.map { "\($0.repoKey)|\($0.path)" })
            guard let next = operations().first(where: {
                $0.state == .pending && !skipped.contains($0.id) && !blockedPaths.contains("\($0.repoKey)|\($0.path)")
            }) else { break }
            guard let source = await resolve(next.repoKey) else {
                update(next.id) { $0.note = "Waiting until you are signed in." }
                skipped.insert(next.id)
                continue
            }
            update(next.id) { $0.state = .sending; $0.note = nil }
            await changed()
            do {
                switch next.kind {
                case .write:
                    guard let data = data(for: next) else { throw BoardSourceError(message: "The saved content for \(next.path) is missing.") }
                    try await source.writeData(path: next.path, data: data, message: next.message)
                case .delete:
                    try await source.delete(path: next.path, message: next.message)
                }
                finish(next)
                sent += 1
                await changed()
            } catch where Outbox.isConnectivity(error) {
                update(next.id) { $0.state = .pending; $0.note = "Waiting for a connection." }
                await changed()
                break
            } catch {
                update(next.id) {
                    $0.state = .failed
                    $0.attempts += 1
                    $0.note = error.localizedDescription
                }
                await changed()
            }
        }
        await changed()
        return sent
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
    private func unsent(_ path: String) async throws -> Data? {
        guard let item = await waiting().first(where: { $0.path == path }) else { return nil }
        guard item.kind == .write, let data = await outbox.data(for: item) else {
            throw BoardSourceError(message: "\(path) was deleted.")
        }
        return data
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
        await outbox.enqueue(repoKey: repoKey, kind: .write, path: path, message: message, data: data)
        saved()
    }

    func delete(path: String, message: String) async throws {
        await outbox.enqueue(repoKey: repoKey, kind: .delete, path: path, message: message, data: nil)
        saved()
    }
}
