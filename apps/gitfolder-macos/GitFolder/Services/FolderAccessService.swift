import AppKit
import Foundation

struct FolderAccessService: Sendable {
    func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = "Add Folder"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func pickPrivateKey() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.prompt = "Choose SSH Key"
        panel.message = "Choose the private SSH key GitFolder should use for GitHub pushes."
        return panel.runModal() == .OK ? panel.url : nil
    }

    func bookmarkData(for url: URL) throws -> Data {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            throw FolderAccessError.bookmarkFailed(url.path, error.localizedDescription)
        }
    }

    func resolveBookmark(_ data: Data) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale {
            throw FolderAccessError.staleBookmark
        }
        return url
    }

    func withSecurityScopedAccess<T>(for folder: SyncedFolder, operation: (URL) throws -> T) throws -> T {
        let url: URL
        if let bookmarkData = folder.bookmarkData {
            do {
                url = try resolveBookmark(bookmarkData)
            } catch {
                let configuredURL = URL(fileURLWithPath: folder.localPath)
                guard FileManager.default.fileExists(atPath: configuredURL.path) else {
                    throw FolderAccessError.bookmarkInvalid(folder.localPath, error.localizedDescription)
                }
                // Development and migrated builds can carry a bookmark signed by a
                // different app build. Use the already-configured path when macOS
                // grants direct access; sandboxed builds will still fail safely at
                // the filesystem boundary and can ask the user to reconnect it.
                url = configuredURL
            }
        } else {
            url = URL(fileURLWithPath: folder.localPath)
        }

        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try operation(url)
    }
}

enum FolderAccessError: LocalizedError, Sendable {
    case bookmarkFailed(String, String)
    case bookmarkInvalid(String, String)
    case staleBookmark

    var errorDescription: String? {
        switch self {
        case .bookmarkFailed(let path, let details):
            "Could not save access to \(path). \(details)"
        case .bookmarkInvalid(let path, let details):
            "Folder access to \(path) needs to be refreshed. \(details)"
        case .staleBookmark:
            "Folder access needs to be refreshed."
        }
    }
}
