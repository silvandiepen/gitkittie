import Foundation

/// Whether a mail folder is somewhere the store can write safely today (GKM-103, MAIL-126).
///
/// The store writes its folder without `NSFileCoordinator` and reads originals as plain files.
/// In iCloud Drive, or a folder another app syncs through File Provider (Dropbox, Google Drive,
/// OneDrive and the like), the system can evict a file to a placeholder, download it while Mail
/// reads it, or change it from another device while Mail writes it. Until the shared iCloud Drive
/// folder is built (GKM-026, apps/gitmail-macos/docs/iCloudDriveDesign.md), such a folder is
/// refused when it is picked, and one already chosen holds the sync back at launch. Nothing is
/// moved: the mail in it stays as it is.
enum MailFolderPlacement: Equatable, Sendable {
    /// An ordinary folder on this device's disk.
    case onThisDevice
    /// In iCloud Drive, including Desktop and Documents when those are in iCloud.
    case iCloudDrive
    /// In a folder another app syncs through File Provider (`~/Library/CloudStorage`).
    case cloudStorage

    /// True when the store may write there.
    var isSafe: Bool { self == .onThisDevice }

    /// Where `folder` is, read from the file system: its resource values (`isUbiquitousItem`, set
    /// for iCloud Drive and File Provider items) and its path. A folder that doesn't exist yet is
    /// judged by the nearest folder above it that does.
    @Sendable static func of(_ folder: URL) -> MailFolderPlacement {
        let resolved = folder.standardizedFileURL.resolvingSymlinksInPath()
        return classify(path: resolved.path(percentEncoded: false), isUbiquitous: isUbiquitous(resolved))
    }

    /// The decision, apart from the file system so it can be tested: the path first, so a File
    /// Provider folder is named as such even though it is ubiquitous too.
    static func classify(path: String, isUbiquitous: Bool) -> MailFolderPlacement {
        let components = URL(filePath: path).standardizedFileURL.pathComponents
        if Self.contains(["Library", "CloudStorage"], in: components) { return .cloudStorage }
        if Self.contains(["Library", "Mobile Documents"], in: components) { return .iCloudDrive }
        return isUbiquitous ? .iCloudDrive : .onThisDevice
    }

    private static func contains(_ run: [String], in components: [String]) -> Bool {
        guard components.count >= run.count else { return false }
        return (0...(components.count - run.count)).contains { Array(components[$0..<($0 + run.count)]) == run }
    }

    private static func isUbiquitous(_ url: URL) -> Bool {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path(percentEncoded: false)) {
            let parent = probe.deletingLastPathComponent()
            guard parent.path != probe.path else { return false }
            probe = parent
        }
        let values = try? probe.resourceValues(forKeys: [.isUbiquitousItemKey])
        return values?.isUbiquitousItem == true
    }
}

extension MailFolderPlacement {
    /// Why a picked folder can't be used, for the alert; nil when it can.
    var refusal: String? {
        switch self {
        case .onThisDevice:
            nil
        case .iCloudDrive:
            "That folder is in iCloud Drive. iCloud can remove files from \(DeviceWords.this) to save space, or change them from another device while Mail is writing, and Mail can’t work with that safely yet. Choose a folder on \(DeviceWords.this) outside iCloud Drive. When Desktop & Documents are in iCloud, that includes your Desktop and Documents folders."
        case .cloudStorage:
            "That folder is synced by another app, such as Dropbox, Google Drive or OneDrive. That app can remove files from \(DeviceWords.this) or change them while Mail is writing, and Mail can’t work with that safely yet. Choose a folder on \(DeviceWords.this) that no app syncs."
        }
    }

    /// The account's status line while the sync is held back.
    var shortText: String? {
        switch self {
        case .onThisDevice: nil
        case .iCloudDrive: "Sync paused · mail folder is in iCloud Drive"
        case .cloudStorage: "Sync paused · mail folder is synced by another app"
        }
    }

    /// The notice: what happened, that nothing was touched, and what to do.
    var text: String? {
        let place: String, away: String
        switch self {
        case .onThisDevice: return nil
        case .iCloudDrive: (place, away) = ("in iCloud Drive", "out of iCloud Drive")
        case .cloudStorage: (place, away) = ("in a folder another app syncs", "out of that app’s folder")
        }
        return "Your mail folder is \(place), where Mail can’t write safely yet, so syncing with your provider is paused. The mail in the folder is untouched. Move the folder \(away) in the Finder and choose it again in Settings ▸ Storage, or use the default mail folder."
    }
}
