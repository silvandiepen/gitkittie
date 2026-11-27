#if os(macOS)
import Foundation

/// The `tasks` command-line tool that ships inside Tasks.app (`Contents/Helpers/tasks`), and
/// putting it on the person's PATH: a symbolic link in a folder they choose (normally
/// `~/.local/bin`), so the command is always the one of the app that is installed.
public enum CommandLineTool {
    public static let name = "tasks"

    /// The tool inside `bundle`, when this build has one.
    public static func bundled(in bundle: Bundle = .main) -> URL? {
        let url = bundle.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// The person's home folder, also inside the sandbox (where `NSHomeDirectory` is the
    /// app's container).
    public static var home: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Where it goes unless the person picks another folder.
    public static var suggestedFolder: URL { home.appendingPathComponent(".local/bin", isDirectory: true) }

    /// The folders a Mac's shells search without any setup.
    static let standardPathFolders = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin"]

    public enum InstallError: LocalizedError, Equatable {
        case notBundled
        case occupied(String)

        public var errorDescription: String? {
            switch self {
            case .notBundled:
                "This copy of Tasks has no command-line tool inside it."
            case .occupied(let path):
                "\(path) already exists and is not a link to Tasks. Move it away, or choose another folder."
            }
        }
    }

    /// Link `folder/tasks` to `tool`. An existing link (an older install, another copy of
    /// the app) is replaced; any other file there is left alone and reported.
    @discardableResult
    public static func install(_ tool: URL, into folder: URL) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent(name)
        if let attributes = try? manager.attributesOfItem(atPath: link.path) {
            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
                throw InstallError.occupied(link.path)
            }
            try manager.removeItem(at: link)
        }
        try manager.createSymbolicLink(at: link, withDestinationURL: tool)
        return link
    }

    /// Where `folder/tasks` points now, when it is a link.
    public static func installedTarget(in folder: URL) -> URL? {
        let link = folder.appendingPathComponent(name)
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return nil }
        return URL(fileURLWithPath: destination, relativeTo: folder).standardizedFileURL
    }

    /// The line to add to the shell's startup file so `folder` is searched, or nil when shells
    /// search it already. (The app cannot see the person's shell PATH, only its own.)
    public static func pathLine(for folder: URL) -> String? {
        let path = folder.standardizedFileURL.path
        if standardPathFolders.contains(path) { return nil }
        let homePath = home.standardizedFileURL.path
        let shown = path.hasPrefix(homePath + "/") ? "$HOME" + path.dropFirst(homePath.count) : path
        return "export PATH=\"\(shown):$PATH\""
    }
}
#endif
