import Foundation
import MailCore

// Pin for offline, storage accounting and cache eviction (GKM-036, MAIL-063).
//
// - A pin is on a message, a conversation or a space, and means "keep all of it here": every
//   partial message it covers is completed (its whole original downloaded once and stored in
//   the mail folder), and nothing it covers is evicted. Pins are your choices, kept in
//   `<device>/metadata/pins.json` beside your classification corrections (to CloudKit with
//   GKM-026), never in the mail folder.
// - Completing is one way. An original in the mail folder is yours and is never evicted, pinned
//   or not; unpinning only lets the cache give back what it fetched for partial messages.
// - Eviction removes only cached parts of partial messages that are not pinned and can be
//   fetched again (the message still has a location at the provider), least recently used
//   first; the parts that came with a partial message's text are kept with it.

/// What can be pinned.
public enum PinTarget: Hashable, Sendable {
    case message(MailMessageID)
    /// A conversation, by thread id.
    case thread(String)
    case space(MailSpaceID)
}

/// Every pin, as stored.
public struct Pins: Codable, Equatable, Sendable {
    public static let version = 1
    public var version = Self.version
    /// Local message id → when it was pinned.
    public var messages: [String: Date] = [:]
    /// Thread id → when. A conversation's id is its oldest message's local id; a pin follows it
    /// when the conversation grows (the pinned id stays a member).
    public var threads: [String: Date] = [:]
    public var spaces: [String: Date] = [:]

    public init() {}

    public var isEmpty: Bool { messages.isEmpty && threads.isEmpty && spaces.isEmpty }
}

/// What offline storage holds, for Settings.
public struct OfflineStorage: Equatable, Sendable {
    /// Parts of partial messages in the device cache.
    public var cacheBytes: Int64 = 0
    public var cachedParts = 0
    /// Of those, what eviction may give back (not pinned, still at the provider).
    public var evictableBytes: Int64 = 0
    /// Messages with attachments still only at the provider.
    public var partialMessages = 0
    /// Their attachments' size at the provider, not downloaded.
    public var notDownloadedBytes: Int64 = 0
    /// Partial messages a pin covers that are not complete yet: waiting for a connection.
    public var pinnedWaiting = 0

    public init() {}
}

/// What an eviction gave back.
public struct EvictionResult: Equatable, Sendable {
    public var removedParts = 0
    public var removedBytes: Int64 = 0
}

extension MailStore {
    private var pinsURL: URL {
        locations.deviceFolder.appendingPathComponent("metadata", isDirectory: true).appendingPathComponent("pins.json")
    }

    // MARK: - Pins

    /// Every pin. A missing file is no pins; a damaged or newer one is an error, never silently
    /// replaced: it holds your choices.
    public func pins() throws -> Pins {
        guard FileManager.default.fileExists(atPath: pinsURL.path) else { return Pins() }
        let pins = try JSONCoding.decoder.decode(Pins.self, from: Data(contentsOf: pinsURL))
        guard pins.version <= Pins.version else { throw MailStoreError.unsupportedMetadataVersion(pins.version) }
        return pins
    }

    /// Pins a message, conversation or space for offline. Returns the partial messages it now
    /// covers: what must be downloaded for it to be all here.
    @discardableResult
    public func pin(_ target: PinTarget, now: Date = Date()) throws -> [MailMessageID] {
        var pins = try pins()
        let at = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        switch target {
        case .message(let id): pins.messages[id.rawValue] = at
        case .thread(let id): pins.threads[id] = at
        case .space(let id): pins.spaces[id.rawValue] = at
        }
        try savePins(pins)
        return try partialMessages(coveredBy: target)
    }

    public func unpin(_ target: PinTarget) throws {
        var pins = try pins()
        switch target {
        case .message(let id): pins.messages[id.rawValue] = nil
        case .thread(let id): pins.threads[id] = nil
        case .space(let id): pins.spaces[id.rawValue] = nil
        }
        try savePins(pins)
    }

    public func isPinned(_ target: PinTarget) throws -> Bool {
        let pins = try pins()
        switch target {
        case .message(let id): return pins.messages[id.rawValue] != nil
        case .thread(let id): return pins.threads[id] != nil
        case .space(let id): return pins.spaces[id.rawValue] != nil
        }
    }

    /// True when any pin covers the message: itself, its conversation or a space holding it.
    public func isKeptOffline(_ id: MailMessageID) throws -> Bool {
        try pinnedMessageIDs(among: [id]).contains(id)
    }

    /// Partial messages that a pin covers: to be completed, oldest first.
    public func pinnedPartialMessages(account: MailAccountID? = nil) throws -> [MailMessageID] {
        let partial = try index.partialIDs(account: account)
        let pinned = try pinnedMessageIDs(among: partial)
        return partial.filter(pinned.contains)
    }

    private func partialMessages(coveredBy target: PinTarget) throws -> [MailMessageID] {
        let covered: Set<MailMessageID>
        switch target {
        case .message(let id): covered = [id]
        case .thread(let id): covered = Set(try index.ids(inThreads: [id]))
        case .space(let id): covered = Set(try index.ids(inSpaces: [id.rawValue]))
        }
        return try index.partialIDs(account: nil).filter(covered.contains)
    }

    /// Which of `ids` a pin covers.
    func pinnedMessageIDs(among ids: [MailMessageID]) throws -> Set<MailMessageID> {
        let pins = try pins()
        guard !pins.isEmpty, !ids.isEmpty else { return [] }
        var covered = Set(ids.filter { pins.messages[$0.rawValue] != nil })
        if !pins.threads.isEmpty { covered.formUnion(try index.ids(inThreads: Array(pins.threads.keys))) }
        if !pins.spaces.isEmpty { covered.formUnion(try index.ids(inSpaces: Array(pins.spaces.keys))) }
        return covered.intersection(ids)
    }

    private func savePins(_ pins: Pins) throws {
        try writer.write(JSONCoding.prettyEncoder.encode(pins), to: pinsURL)
    }

    // MARK: - Storage and eviction

    /// What the offline cache and the partial messages hold now.
    public func offlineStorage() throws -> OfflineStorage {
        var storage = OfflineStorage()
        let survey = try surveyCache()
        storage.cachedParts = survey.files.count
        storage.cacheBytes = survey.files.reduce(0) { $0 + $1.size }
        storage.evictableBytes = survey.files.filter { survey.evictable[$0.blob] != nil }.reduce(0) { $0 + $1.size }
        storage.partialMessages = survey.partialCount
        storage.notDownloadedBytes = survey.notDownloadedBytes
        storage.pinnedWaiting = survey.pinnedCount
        return storage
    }

    /// Gives cache space back until the cache holds at most `budget` bytes: first parts nothing
    /// refers to any more, then parts fetched on demand for partial messages that are not
    /// pinned and are still at the provider, least recently used first. A part given back is
    /// listed as not downloaded again and is fetched again when opened.
    @discardableResult
    public func evictCache(toFit budget: Int64) throws -> EvictionResult {
        var result = EvictionResult()
        let survey = try surveyCache()
        var total = survey.files.reduce(Int64(0)) { $0 + $1.size }
        let fileManager = FileManager.default
        // Unreferenced parts (their message was completed or removed) go whatever the budget.
        for file in survey.files where !survey.referenced.contains(file.blob) {
            try fileManager.removeItem(at: cacheBlobURL(file.blob))
            total -= file.size
            result.removedParts += 1
            result.removedBytes += file.size
        }
        guard total > budget else { return result }
        var changed: [MailMessageID: (account: String, manifest: PartialManifest)] = [:]
        let candidates = survey.files.filter { survey.referenced.contains($0.blob) && survey.evictable[$0.blob] != nil }
            .sorted { ($0.used, $0.blob) < ($1.used, $1.blob) }
        for file in candidates where total > budget {
            for (id, account, section) in survey.evictable[file.blob] ?? [] {
                if changed[id] == nil {
                    guard let manifest = try readManifest(id, account: account) else { continue }
                    changed[id] = (account, manifest)
                }
                changed[id]?.manifest.fetched[section] = nil
            }
            try fileManager.removeItem(at: cacheBlobURL(file.blob))
            total -= file.size
            result.removedParts += 1
            result.removedBytes += file.size
        }
        for (_, entry) in changed.sorted(by: { $0.key < $1.key }) {
            _ = try rewriteManifest(entry.manifest, account: entry.account)
        }
        return result
    }

    private struct CacheSurvey {
        var files: [(blob: String, size: Int64, used: Date)] = []
        /// Blobs some partial message refers to.
        var referenced = Set<String>()
        /// Blobs only unpinned, re-fetchable partial messages refer to, and only as parts fetched
        /// on demand: with every (message, account, section) that would lose it.
        var evictable: [String: [(MailMessageID, String, String)]] = [:]
        var partialCount = 0
        var pinnedCount = 0
        var notDownloadedBytes: Int64 = 0
    }

    private func surveyCache() throws -> CacheSurvey {
        var survey = CacheSurvey()
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: locations.cacheBlobsFolder.path) {
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
            for url in try fileManager.contentsOfDirectory(at: locations.cacheBlobsFolder, includingPropertiesForKeys: Array(keys)) {
                guard SafePath.isSHA256Hex(url.lastPathComponent) else { continue }
                let values = try url.resourceValues(forKeys: keys)
                survey.files.append((url.lastPathComponent, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
            }
        }
        let partial = try index.partialIDs(account: nil)
        survey.partialCount = partial.count
        let pinned = try pinnedMessageIDs(among: partial)
        var protected = Set<String>()
        for id in partial {
            guard let account = try index.account(of: id) else { continue }
            let name = try SafePath.component(account.rawValue)
            guard let manifest = try readManifest(id, account: name),
                  let skeleton = try? Data(contentsOf: partialSkeletonURL(id, account: name)) else { continue }
            let derived = try derivePartial(skeleton, manifest: manifest)
            for attachment in derived.front.attachments where attachment.isDownloaded {
                survey.referenced.insert(attachment.blob)
                if attachment.section == nil { protected.insert(attachment.blob) } // came with the text
            }
            survey.notDownloadedBytes += Int64(derived.front.attachments.filter { !$0.isDownloaded }.reduce(0) { $0 + $1.size })
            let refetchable = try !mapping(for: name).locations(of: id).isEmpty
            if pinned.contains(id) {
                survey.pinnedCount += 1
                protected.formUnion(manifest.fetched.values.map(\.blob))
            } else if refetchable {
                for (section, part) in manifest.fetched { survey.evictable[part.blob, default: []].append((id, name, section)) }
            } else {
                protected.formUnion(manifest.fetched.values.map(\.blob))
            }
        }
        for blob in protected { survey.evictable[blob] = nil }
        return survey
    }
}

extension MailIndex {
    /// Messages in conversations whose id is one of `threadIDs`, or that hold a message with one
    /// of those ids (a conversation keeps the pin when an older message joins it).
    func ids(inThreads threadIDs: [String]) throws -> [MailMessageID] {
        guard !threadIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: threadIDs.count).joined(separator: ",")
        let statement = try database.prepare("""
            SELECT local_id FROM messages WHERE thread_id IN (\(placeholders))
               OR thread_id IN (SELECT thread_id FROM messages WHERE local_id IN (\(placeholders)))
            """).bind((threadIDs + threadIDs).map(SQLiteValue.text))
        var ids: [MailMessageID] = []
        while try statement.step() { if let raw = statement.text(0), let id = MailMessageID(raw) { ids.append(id) } }
        return ids
    }

    func ids(inSpaces spaceIDs: [String]) throws -> [MailMessageID] {
        guard !spaceIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: spaceIDs.count).joined(separator: ",")
        let statement = try database.prepare("SELECT DISTINCT local_id FROM space_members WHERE space_id IN (\(placeholders))")
            .bind(spaceIDs.map(SQLiteValue.text))
        var ids: [MailMessageID] = []
        while try statement.step() { if let raw = statement.text(0), let id = MailMessageID(raw) { ids.append(id) } }
        return ids
    }
}
