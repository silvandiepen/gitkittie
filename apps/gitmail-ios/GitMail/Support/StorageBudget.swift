import Foundation
import MailSync

/// The iPhone's and iPad's limits on what mail takes (MAIL-051, MAIL-068). Phones have less
/// space and pay for cellular data, so the iOS app sets limits the Mac does not need. These are
/// defaults the person can change in Settings ▸ Storage.
///
/// What each limit does today:
/// - `historyBytes`: older mail is downloaded up to this many bytes per account, newest first;
///   then the sync says "older mail paused at the storage limit". New mail always comes in.
/// - `recentPerFolder`: a folder's newest messages that come in before any history.
/// - `cacheBytes`: the device folder's `cache/` (previews, attachment copies) is kept under
///   this, least recently used first, and is never backed up.
/// - `minimumFreeBytes`: under this much free space the sync stops, with a message, until there
///   is room again. Mail already stored is never removed to make room: it is the person's (MAIL-003).
struct StorageBudget: Equatable, Codable {
    var historyBytes: Int64 = 500 * 1024 * 1024
    var recentPerFolder = 200
    var cacheBytes: Int64 = 500 * 1024 * 1024
    var minimumFreeBytes: Int64 = 1024 * 1024 * 1024

    static let standard = StorageBudget()

    /// The choices Settings offers for the history limit; `nil` is no limit.
    static let historyChoices: [Int64?] = [100 * 1024 * 1024, 500 * 1024 * 1024, 2 * 1024 * 1024 * 1024, nil]

    /// `historyBytes` of 0 is stored for "no limit" (Codable keeps it simple).
    var historyLimit: Int64? { historyBytes > 0 ? historyBytes : nil }

    /// The sync's options under this budget: the Mac's defaults with the history limit.
    var syncOptions: SyncOptions {
        SyncOptions(recentPerFolder: recentPerFolder, historyBudgetBytes: historyLimit)
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
    /// removed record would let bytes that crashed the app be parsed again (MAIL-052).
    static let keptFolders: Set<String> = ["attachment-text-attempts"]

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
