import Foundation

/// What can go wrong in the store. Messages name the problem, never a message's contents.
public enum MailStoreError: Error, Equatable, CustomStringConvertible {
    /// A name that would be used as a path segment is not safe (traversal, separators, …).
    case unsafePathComponent(String)
    /// The device-local folder sits inside the mail folder, or the other way round (MAIL-013).
    case deviceStateInsideMailFolder
    /// A file's bytes do not match the hash recorded for it.
    case integrityMismatch(path: String)
    /// The message bytes could not be read as RFC 5322 at all.
    case unparseableMessage(String)
    /// No message with this id in the store.
    case messageNotFound(String)
    /// The folder was written by a newer version of the app than this one.
    case unsupportedLayoutVersion(Int)
    /// A file system call failed.
    case io(operation: String, path: String, code: Int32)
    /// SQLite reported an error.
    case sqlite(code: Int32, message: String)

    public var description: String {
        switch self {
        case .unsafePathComponent(let s): return "Unsafe path component: \(s.debugDescription)"
        case .deviceStateInsideMailFolder: return "The index and sync state must live outside the mail folder."
        case .integrityMismatch(let path): return "File does not match its recorded hash: \(path)"
        case .unparseableMessage(let why): return "Not a readable message: \(why)"
        case .messageNotFound(let id): return "No message \(id)"
        case .unsupportedLayoutVersion(let v): return "The mail folder uses layout version \(v), newer than this app understands."
        case .io(let op, let path, let code): return "\(op) failed for \(path): \(String(cString: strerror(code)))"
        case .sqlite(let code, let message): return "SQLite error \(code): \(message)"
        }
    }
}
