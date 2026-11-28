import Foundation

/// Every file and folder under a folder with its size and modification time, to prove that
/// nothing in it was created, changed or removed (GKM-104). Folders count: a folder's
/// modification time changes when a file is added to it or taken out.
struct FolderSnapshot: Equatable, CustomStringConvertible {
    struct Entry: Equatable {
        var isDirectory: Bool
        var size: Int
        var modified: Date
    }

    private(set) var entries: [String: Entry] = [:]

    init(of folder: URL) throws {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard FileManager.default.fileExists(atPath: root),
              let walker = FileManager.default.enumerator(at: URL(filePath: root), includingPropertiesForKeys: Array(keys)) else { return }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: keys)
            let path = String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(root.count))
            entries[path] = Entry(isDirectory: values.isDirectory ?? false, size: values.fileSize ?? 0,
                                  modified: values.contentModificationDate ?? .distantPast)
        }
    }

    var paths: [String] { entries.keys.sorted() }

    /// What differs from `other`, one line each: for the failure message.
    func differences(from other: FolderSnapshot) -> [String] {
        var lines: [String] = []
        for path in Set(entries.keys).union(other.entries.keys).sorted() {
            switch (other.entries[path], entries[path]) {
            case (nil, .some): lines.append("added \(path)")
            case (.some, nil): lines.append("removed \(path)")
            case (.some(let before), .some(let after)) where before != after: lines.append("changed \(path)")
            default: break
            }
        }
        return lines
    }

    var description: String { paths.joined(separator: "\n") }
}
