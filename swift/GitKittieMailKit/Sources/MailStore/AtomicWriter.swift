import Foundation

/// A point in a message write where a test can stop the store, as if the process were killed.
public enum WriteStep: Equatable, Sendable {
    /// The file's bytes are on disk under a temporary name; the rename has not happened.
    case beforeRename(fileName: String)
    /// Both files of a message are in place; the index and the remote mapping are not updated.
    case beforeIndex
}

/// Test hook: called at each `WriteStep`. Throwing from it stops the write at that point and
/// leaves exactly what a killed process would leave, because the store never tidies up after a
/// failed write in the same breath: the next `open` does that, through one recovery path that
/// serves crashes and errors alike.
public struct WriteFaults: Sendable {
    public var hook: (@Sendable (WriteStep) throws -> Void)?
    public init(hook: (@Sendable (WriteStep) throws -> Void)? = nil) { self.hook = hook }
    public static let none = WriteFaults()

    func check(_ step: WriteStep) throws { try hook?(step) }
}

/// A file written under a temporary name in its final directory, flushed, not yet visible.
struct StagedFile {
    let temporary: URL
    let destination: URL
}

/// Atomic file writes: bytes go to a hidden temporary file in the destination's own directory
/// (same volume, so the rename is atomic), are flushed with `fsync`, and only then renamed over
/// the destination. A reader sees the old file or the new one, never a torn one.
struct AtomicWriter {
    /// Suffix of temporary files; recovery removes any it finds.
    static let partialSuffix = ".partial"

    var faults: WriteFaults

    func write(_ data: Data, to destination: URL) throws {
        try commit(stage(data, for: destination))
    }

    func stage(_ data: Data, for destination: URL) throws -> StagedFile {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString.lowercased())\(Self.partialSuffix)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw MailStoreError.io(operation: "open", path: temporary.path, code: errno) }
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Foundation.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw MailStoreError.io(operation: "write", path: temporary.path, code: errno)
                    }
                    offset += written
                }
            }
            guard fsync(fd) == 0 else { throw MailStoreError.io(operation: "fsync", path: temporary.path, code: errno) }
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else { throw MailStoreError.io(operation: "close", path: temporary.path, code: errno) }
        return StagedFile(temporary: temporary, destination: destination)
    }

    func commit(_ staged: StagedFile) throws {
        try faults.check(.beforeRename(fileName: staged.destination.lastPathComponent))
        guard rename(staged.temporary.path, staged.destination.path) == 0 else {
            throw MailStoreError.io(operation: "rename", path: staged.destination.path, code: errno)
        }
        try Self.syncDirectory(staged.destination.deletingLastPathComponent())
    }

    /// Flush a directory so a rename in it survives power loss, not only a crash.
    static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw MailStoreError.io(operation: "open", path: directory.path, code: errno) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw MailStoreError.io(operation: "fsync", path: directory.path, code: errno) }
    }
}
