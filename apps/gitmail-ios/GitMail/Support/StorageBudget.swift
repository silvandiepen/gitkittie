import Foundation
import MailSync

/// The iPhone's and iPad's limits on what mail takes (MAIL-051, MAIL-068). Phones have less
/// space and pay for cellular data, so the iOS app sets limits the Mac does not need. These are
/// defaults the person can change in Settings ▸ Storage; Sil chose the smaller set (GKM-025,
/// MAIL-079): 14 days, attachments only when opened, a 250 MB cache.
///
/// What each limit does today:
/// - `historyDays`: a folder's first sync downloads only the mail received in the last this many
///   days (MAIL-072); older mail stays at the provider until the person asks for it, and the
///   sync says "older than 14 days not downloaded". New mail always comes in, whatever its date.
/// - `historyBytes`: older mail is downloaded up to this many bytes per account, newest first;
///   then the sync says "older mail paused at the storage limit". New mail always comes in.
/// - `recentPerFolder`: a folder's newest messages that come in before any history.
/// - `attachmentsWhenOpened`: every attachment stays at the provider until it is opened or
///   pinned (the sync's on-demand threshold at 0, MAIL-062); off, only attachments over 1 MB do,
///   as on the Mac.
/// - `cacheBytes`: the device folder's `cache/` (opened attachments, previews) is kept under
///   this, least recently used first, and is never backed up. Attachments go back through the
///   store's eviction, which never gives back a pinned part or one that cannot be fetched again.
/// - `minimumFreeBytes`: under this much free space the sync stops, with a message, until there
///   is room again. Mail already stored is never removed to make room: it is the person's (MAIL-003).
struct StorageBudget: Equatable, Codable {
    /// 2: the GKM-025 defaults. A budget saved without a version was saved under the first
    /// defaults (30 days, a 500 MB cache, attachments over 1 MB on demand).
    static let currentVersion = 2

    var version = Self.currentVersion
    var historyDays = 14
    var historyBytes: Int64 = 500 * 1024 * 1024
    var recentPerFolder = 200
    var attachmentsWhenOpened = true
    var cacheBytes: Int64 = 250 * 1024 * 1024
    var minimumFreeBytes: Int64 = 1024 * 1024 * 1024

    static let standard = StorageBudget()

    /// The first defaults (MAIL-068, MAIL-072). A saved budget that still holds one of them moves
    /// to the new default; a value the person changed stays.
    enum FirstDefaults {
        static let historyDays = 30
        static let cacheBytes: Int64 = 500 * 1024 * 1024
    }

    /// The choices Settings offers for the history limit; `nil` is no limit.
    static let historyChoices: [Int64?] = [100 * 1024 * 1024, 500 * 1024 * 1024, 2 * 1024 * 1024 * 1024, nil]

    /// The choices Settings offers for the history window, in days; `nil` is all of it.
    static let historyDayChoices: [Int?] = [14, 30, 90, 365, nil]

    /// The choices Settings offers for the cache.
    static let cacheChoices: [Int64] = [100, 250, 500, 1000].map { Int64($0) * 1024 * 1024 }

    /// `historyBytes` of 0 is stored for "no limit" (Codable keeps it simple).
    var historyLimit: Int64? { historyBytes > 0 ? historyBytes : nil }

    /// `historyDays` of 0 is stored for "all of it", as `historyBytes`.
    var historyWindow: Int? { historyDays > 0 ? historyDays : nil }

    /// The sync's options under this budget: the Mac's defaults with the history window and
    /// limit, and every attachment on demand when `attachmentsWhenOpened`.
    var syncOptions: SyncOptions {
        var options = SyncOptions(recentPerFolder: recentPerFolder, historyBudgetBytes: historyLimit, historyDays: historyWindow)
        if attachmentsWhenOpened { options.onDemandThreshold = 0 }
        return options
    }

    init() {}

    /// A budget saved before a limit existed keeps its choices and takes that limit's default.
    /// One saved under the first defaults (no `version`) moves each value that is still a first
    /// default to the new one, and keeps what the person changed.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = StorageBudget()
        let saved = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        historyDays = try container.decodeIfPresent(Int.self, forKey: .historyDays) ?? standard.historyDays
        historyBytes = try container.decodeIfPresent(Int64.self, forKey: .historyBytes) ?? standard.historyBytes
        recentPerFolder = try container.decodeIfPresent(Int.self, forKey: .recentPerFolder) ?? standard.recentPerFolder
        attachmentsWhenOpened = try container.decodeIfPresent(Bool.self, forKey: .attachmentsWhenOpened) ?? standard.attachmentsWhenOpened
        cacheBytes = try container.decodeIfPresent(Int64.self, forKey: .cacheBytes) ?? standard.cacheBytes
        minimumFreeBytes = try container.decodeIfPresent(Int64.self, forKey: .minimumFreeBytes) ?? standard.minimumFreeBytes
        if saved < 2 {
            if historyDays == FirstDefaults.historyDays { historyDays = standard.historyDays }
            if cacheBytes == FirstDefaults.cacheBytes { cacheBytes = standard.cacheBytes }
        }
        version = Self.currentVersion
    }

    // MARK: Persistence

    static let defaultsKey = "storageBudget"

    static func load(from defaults: UserDefaults) -> StorageBudget {
        guard let data = defaults.data(forKey: defaultsKey),
              let budget = try? JSONDecoder().decode(StorageBudget.self, from: data) else { return .standard }
        return budget
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// The device folder's cache: never backed up, and trimmed to the budget (MAIL-051).
enum DeviceCache {
    /// Crash records of attachment text extraction live in the cache but are never evicted: a
    /// removed record would let bytes that crashed the app be parsed again (MAIL-052). Parts of
    /// partial messages (`blobs`) are given back only by `MailStore.evictCache(toFit:)`, which
    /// keeps pinned parts and parts that cannot be fetched again (MAIL-064).
    static let keptFolders: Set<String> = ["attachment-text-attempts", "blobs"]

    static func folder(in deviceFolder: URL) -> URL {
        deviceFolder.appendingPathComponent("cache", isDirectory: true)
    }

    /// Creates the cache folder if needed and marks it excluded from iCloud and device backups.
    static func prepare(deviceFolder: URL) throws {
        var cache = folder(in: deviceFolder)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try cache.setResourceValues(values)
    }

    /// Removes the least recently used files until the cache is under `limit` bytes. Returns the
    /// bytes removed.
    @discardableResult
    static func trim(deviceFolder: URL, to limit: Int64, fileManager: FileManager = .default) -> Int64 {
        let cache = folder(in: deviceFolder)
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey,
                                      .contentAccessDateKey, .contentModificationDateKey]
        guard let walker = fileManager.enumerator(at: cache, includingPropertiesForKeys: keys) else { return 0 }
        var files: [(url: URL, size: Int64, used: Date)] = []
        var total: Int64 = 0
        for case let url as URL in walker {
            let relative = url.path.dropFirst(cache.path.count).split(separator: "/").first.map(String.init)
            if let relative, keptFolders.contains(relative) {
                if url.hasDirectoryPath { walker.skipDescendants() }
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            let used = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
            files.append((url, size, used))
            total += size
        }
        guard total > limit else { return 0 }
        var removed: Int64 = 0
        for file in files.sorted(by: { $0.used < $1.used }) {
            guard total - removed > limit else { break }
            if (try? fileManager.removeItem(at: file.url)) != nil { removed += file.size }
        }
        return removed
    }
}

/// Free space on the device, as iOS reports it for things the person asked for.
enum FreeSpace {
    static func available(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
