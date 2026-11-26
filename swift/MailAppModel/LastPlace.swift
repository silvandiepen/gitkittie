import Foundation

/// Where the window was left, so Mail opens there again (MAIL-107, GKM-067): the sidebar's
/// selection (a category, All Mail, an account, a folder, a space, Drafts…) and the conversation
/// open in it. Kept on this device in `preferences/last-place.json`, beside the account order:
/// another device has its own. Written as the place changes, so a quit, a crash or iOS ending
/// the app in the background all keep it.
struct LastPlace: Codable, Equatable {
    var selection: SidebarSelection
    /// The open conversation's thread id; nil when none was open.
    var threadID: String?

    static func url(deviceFolder: URL) -> URL {
        deviceFolder.appendingPathComponent("preferences", isDirectory: true).appendingPathComponent("last-place.json")
    }

    /// Nil when nothing was saved yet, or the file can't be read: the window opens in Focused.
    static func load(deviceFolder: URL) -> LastPlace? {
        guard let data = try? Data(contentsOf: url(deviceFolder: deviceFolder)) else { return nil }
        return try? JSONDecoder().decode(LastPlace.self, from: data)
    }

    func save(deviceFolder: URL) throws {
        let url = Self.url(deviceFolder: deviceFolder)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
