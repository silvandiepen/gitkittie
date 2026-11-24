import CryptoKit
import Foundation
import MailStore

/// Where the mail folder is (MAIL-021): `Documents/Mail` in the app's container by default, or
/// a folder the person chose, remembered as a security-scoped bookmark (GKM-010).
///
/// The device state (index, mapping, cursors) belongs to one mail folder: it says which of
/// *that* folder's messages are where at the provider. So each chosen folder gets its own
/// device folder under Application Support, named by a hash of the folder's path; going back
/// to a folder finds its state again, and a new folder never inherits another's.
struct MailFolderLocation {
    static let bookmarkKey = "mailFolderBookmark"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The chosen folder, if there is one and it can still be found. Starts security-scoped
    /// access, which lasts for the life of the app.
    func chosenFolder() -> URL? {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if isStale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: Self.bookmarkKey)
        }
        return url
    }

    /// Remembers a folder the person picked (from an open panel, which grants access).
    func choose(_ url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: Self.bookmarkKey)
        _ = url.startAccessingSecurityScopedResource()
    }

    /// Back to the default folder.
    func reset() {
        defaults.removeObject(forKey: Self.bookmarkKey)
    }

    /// The store's two folders for the current choice.
    func locations() throws -> StoreLocations {
        let standard = try StoreLocations.standard()
        guard let folder = chosenFolder() else { return standard }
        return Self.locations(for: folder, standard: standard)
    }

    /// A chosen mail folder with its own device state beside the default one.
    static func locations(for folder: URL, standard: StoreLocations) -> StoreLocations {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        if path == standard.mailFolder.standardizedFileURL.resolvingSymlinksInPath().path { return standard }
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let device = standard.deviceFolder.appendingPathComponent("folders", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
        return StoreLocations(mailFolder: folder, deviceFolder: device)
    }
}
