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
    /// Your classification corrections were written by a newer version of the app (GKM-017).
    case unsupportedMetadataVersion(Int)
    /// A file system call failed.
    case io(operation: String, path: String, code: Int32)
    /// SQLite reported an error.
    case sqlite(code: Int32, message: String)
    /// No space with this id in the folder (GKM-022).
    case spaceNotFound(String)
    /// A space change that cannot be saved: no name, a rule without conditions.
    case invalidSpace(String)
    /// The space file was written by a newer version of the app; it is shown, never rewritten.
    case unsupportedSpaceFormat(Int)
    /// An export destination that is not a folder this app may write to (GKM-023).
    case exportDestinationUnavailable(String)
    /// The message is partial (GKM-036): its original is not stored yet, so nothing may treat
    /// what is stored as the original. Complete it first.
    case partialMessage(String)
    /// An attachment of a partial message that is still only at the provider (GKM-036).
    case attachmentNotDownloaded(String)
    /// Bytes offered to complete a partial message are not that message: header, size or a
    /// fetched part differ (GKM-036).
    case partialMismatch(String)
    /// Writing would leave less free space on the mail folder's disk than the sync's minimum
    /// (``FreeSpaceFloor``, GKM-091). Nothing of the batch was written.
    case diskNearlyFull(freeBytes: Int64, minimumFreeBytes: Int64)

    public var description: String {
        switch self {
        case .unsafePathComponent(let s): return "Unsafe path component: \(s.debugDescription)"
        case .deviceStateInsideMailFolder: return "The index and sync state must live outside the mail folder."
        case .integrityMismatch(let path): return "File does not match its recorded hash: \(path)"
        case .unparseableMessage(let why): return "Not a readable message: \(why)"
        case .messageNotFound(let id): return "No message \(id)"
        case .unsupportedLayoutVersion(let v): return "The mail folder uses layout version \(v), newer than this app understands."
        case .unsupportedMetadataVersion(let v): return "Your classification corrections use version \(v), newer than this app understands."
        case .io(let op, let path, let code): return "\(op) failed for \(path): \(String(cString: strerror(code)))"
        case .sqlite(let code, let message): return "SQLite error \(code): \(message)"
        case .spaceNotFound(let id): return "No space \(id)"
        case .invalidSpace(let why): return why
        case .unsupportedSpaceFormat(let v): return "This space was saved by a newer version of the app (format \(v)); it can be read but not changed here."
        case .exportDestinationUnavailable(let path): return "Can’t write the export to \(path)."
        case .partialMessage(let id): return "Message \(id) is not completely downloaded yet."
        case .attachmentNotDownloaded(let name): return "“\(name)” is not downloaded yet."
        case .partialMismatch(let id): return "The downloaded message does not match the partial copy of \(id)."
        case .diskNearlyFull(let free, let minimum): return "Only \(free) bytes free on the mail folder's disk; the sync keeps \(minimum) free."
        }
    }
}
