import Foundation
import SQLite3

/// The least free space the sync leaves on the disk that holds the mail folder (GKM-091,
/// MAIL-123). The sync checks it before each batch it downloads, and the store again before it
/// writes a batch, so neither a sync between the app's own checks nor one started some other way
/// can fill the disk: nothing of the batch is written when it would leave less than the minimum.
///
/// The minimum is the app's (`AccountServices.minimumFreeBytes`: 2 GB on the Mac, the storage
/// budget's minimum on iPhone and iPad, MAIL-106); this type only carries it. What the person
/// asks for (an attachment opened, a message found on the server) is not held to it (MAIL-106).
public struct FreeSpaceFloor: Sendable {
    /// Writing stops before free space would drop under this.
    public var minimumFreeBytes: Int64
    /// Free space on the volume that holds a folder; nil when it can't be read.
    public var available: @Sendable (URL) -> Int64?

    public init(minimumFreeBytes: Int64, available: @escaping @Sendable (URL) -> Int64? = FreeSpaceFloor.volumeAvailable(at:)) {
        self.minimumFreeBytes = minimumFreeBytes
        self.available = available
    }

    /// Free space on the volume, as the system reports it for things the person asked for
    /// (purgeable space counted as free, as Finder does).
    public static func volumeAvailable(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Throws ``MailStoreError/diskNearlyFull(freeBytes:minimumFreeBytes:)`` when writing
    /// `incoming` more bytes into `folder` would leave less than the minimum free. A volume whose
    /// free space can't be read is taken to have room, as the app's pause does; a write that
    /// then fails for space says so as ``LocalStoreProblem/diskFull``.
    public func check(incoming: Int64, in folder: URL) throws {
        guard let free = available(folder) else { return }
        guard free - max(0, incoming) >= minimumFreeBytes else {
            throw MailStoreError.diskNearlyFull(freeBytes: free, minimumFreeBytes: minimumFreeBytes)
        }
    }
}

/// Why the store could not write, in the terms the person can act on (GKM-091, MAIL-124): read
/// from the error a write or a database call threw. Nil for errors that are not about the disk
/// or the folder (a message that can't be parsed, say).
public enum LocalStoreProblem: Sendable, Equatable {
    /// The disk is full (`ENOSPC`, a quota, `SQLITE_FULL`).
    case diskFull
    /// The mail folder, or Mail's records on this device, can't be written: permissions, a
    /// read-only volume or folder.
    case notWritable
    /// The mail folder or its disk is not there: moved, deleted, or the volume is unmounted.
    case folderUnavailable
    /// Mail's records on this device are damaged (a database SQLite can't read).
    case damaged

    public init?(_ error: any Error) {
        switch error {
        case MailStoreError.io(_, _, let code):
            guard let problem = Self(posix: code) else { return nil }
            self = problem
        case MailStoreError.sqlite(let code, _):
            guard let problem = Self(sqlite: code) else { return nil }
            self = problem
        case MailStoreError.diskNearlyFull:
            self = .diskFull
        case let error as CocoaError:
            guard let problem = Self(cocoa: error) else { return nil }
            self = problem
        case let error as POSIXError:
            guard let problem = Self(posix: error.code.rawValue) else { return nil }
            self = problem
        default:
            let error = error as NSError
            guard error.domain == NSPOSIXErrorDomain, let problem = Self(posix: Int32(error.code)) else { return nil }
            self = problem
        }
    }

    init?(posix code: Int32) {
        switch code {
        case ENOSPC, EDQUOT: self = .diskFull
        case EACCES, EPERM, EROFS: self = .notWritable
        case ENOENT, ENOTDIR, ENXIO, ENODEV, EIO: self = .folderUnavailable
        default: return nil
        }
    }

    init?(sqlite code: Int32) {
        // Extended codes keep the primary code in the low byte.
        switch code & 0xff {
        case SQLITE_FULL: self = .diskFull
        case SQLITE_READONLY, SQLITE_PERM: self = .notWritable
        case SQLITE_CANTOPEN, SQLITE_IOERR: self = .folderUnavailable
        case SQLITE_CORRUPT, SQLITE_NOTADB: self = .damaged
        default: return nil
        }
    }

    init?(cocoa error: CocoaError) {
        switch error.code {
        case .fileWriteOutOfSpace: self = .diskFull
        case .fileWriteNoPermission, .fileWriteVolumeReadOnly, .fileReadNoPermission: self = .notWritable
        case .fileNoSuchFile, .fileReadNoSuchFile: self = .folderUnavailable
        default:
            guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain,
                  let problem = Self(posix: Int32(underlying.code)) else { return nil }
            self = problem
        }
    }
}
