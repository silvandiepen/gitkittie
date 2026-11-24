import Foundation

/// Path rules for everything the store writes. No name that came from a message (a subject, an
/// attachment's file name, a Message-ID) is ever used as a path segment: messages are named by
/// their local UUID and attachments by their SHA-256. Account ids are checked here too, because
/// they arrive from the folder and from sync.
enum SafePath {
    /// A single path segment we made ourselves: letters, digits, `-` and `_`, 1–64 long, not
    /// starting with a dot. Anything else is refused, not cleaned up.
    static func component(_ value: String) throws -> String {
        guard (1...64).contains(value.count),
              value.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !value.hasPrefix(".") else {
            throw MailStoreError.unsafePathComponent(value)
        }
        return value
    }

    /// True for a lowercase hex SHA-256 — the only shape a blob name can have.
    static func isSHA256Hex(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { hex.contains($0) }
    }

    /// True when `url` resolves to a location inside `root` (or is `root`), after symlinks and
    /// `..` are resolved. A last line of defence: callers build paths from checked components.
    static func isContained(_ url: URL, in root: URL) -> Bool {
        let child = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let parent = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return child.count >= parent.count && Array(child.prefix(parent.count)) == parent
    }

    /// A file name an attachment can be shown with: no separators, no control characters, no
    /// leading dots, at most 120 characters. For display and export suggestions only.
    static func displayFileName(_ raw: String?) -> String {
        let cleaned = (raw ?? "")
            .unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) || $0 == "/" || $0 == "\\" || $0 == ":" ? "_" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        let trimmed = String(cleaned.drop(while: { $0 == "." }))
        let name = trimmed.isEmpty ? "attachment" : trimmed
        return String(name.prefix(120))
    }

    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    private static let hex = CharacterSet(charactersIn: "0123456789abcdef")
}
