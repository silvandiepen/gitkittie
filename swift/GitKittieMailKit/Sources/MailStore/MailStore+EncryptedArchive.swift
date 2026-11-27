import CryptoKit
import Foundation
import MailCore

// Encrypted archive export and restore (GKM-032; MAIL-128..130; format in Architecture.md,
// "Encrypted archive"). One file holds everything the person owns: the whole mail folder
// (originals byte for byte, their Markdown, attachment blobs, accounts without passwords, spaces
// with their rules, drafts, layout.json) and the user metadata from the device folder that
// restores rules and corrections (classification.json, sender-rules.json, unsubscribes.json).
// Device state (index, sync cursors and mapping, the action journal, the outbox, caches, partial
// messages, pins, preferences) is never in it: a restored folder rebuilds its index on open and
// meets its providers as a new device would.
//
// Writing reads the mail folder directly, outside the store's actor, so sync and the window
// keep working during a long archive. Files are written atomically by rename and originals are
// never rewritten, so each file read is a whole version of it; a file removed meanwhile is
// left out.

/// What writing an encrypted archive did.
public struct EncryptedArchiveResult: Sendable {
    /// The archive it wrote.
    public var file: URL
    /// The only way to open it. Show it once; the app keeps no copy.
    public var recoveryKey: ArchiveRecoveryKey
    public var messages: Int
    public var attachments: Int
    /// Every file in the archive, messages, Markdown, blobs, spaces and metadata included.
    public var files: Int
    /// Their size before encryption.
    public var bytes: Int64
    /// Messages left out because their original no longer matches its recorded hash (as export
    /// does, MAIL-044): a changed original is the person's to look at.
    public var failed: [MailMessageID]
    /// Partial messages (GKM-036), left out: what is stored of them is not the message.
    public var partial: [MailMessageID]
}

/// What a restore wrote.
public struct EncryptedArchiveRestoreResult: Equatable, Sendable {
    public var messages: Int
    public var files: Int
    public var bytes: Int64
}

extension MailStore {
    /// Writes an encrypted archive of everything the person owns into `destination`, as
    /// `<name>.gkmarchive` (a number is added rather than overwriting), under a new recovery key.
    /// The file appears under its name only once it is complete; on any error nothing is left.
    public nonisolated func writeEncryptedArchive(to destination: URL, name: String? = nil, now: Date = Date()) async throws -> EncryptedArchiveResult {
        try await writeEncryptedArchive(to: destination, name: name, now: now, recoveryKey: .generate(), chunkSize: ArchiveFormat.defaultChunkSize)
    }

    nonisolated func writeEncryptedArchive(to destination: URL, name: String?, now: Date, recoveryKey: ArchiveRecoveryKey,
                                           chunkSize: Int) async throws -> EncryptedArchiveResult {
        let partial = try await partialMessages()
        return try EncryptedArchive.write(locations: locations, to: destination, name: name, now: now, recoveryKey: recoveryKey,
                                          chunkSize: chunkSize, partial: partial)
    }
}

public enum EncryptedArchive {
    /// The archive's file extension.
    public static let fileExtension = ArchiveFormat.fileExtension

    /// The device folder's user metadata that comes along (MAIL-128): rules and corrections,
    /// sender rules, and the unsubscribe requests already sent.
    static let deviceMetadataFiles = ["classification.json", "sender-rules.json", "unsubscribes.json"]

    /// Decrypts `archive` with `recoveryKey`, checks every record and every file, and writes
    /// the mail folder and the device metadata into `locations`, which must not exist yet (or be
    /// empty folders). Everything goes into hidden folders beside them first and is moved into
    /// place only when the whole archive has checked out: a wrong key, a damaged or cut archive
    /// leaves nothing behind. `MailStore.open(locations)` then rebuilds the index.
    public static func restore(_ archive: URL, recoveryKey: ArchiveRecoveryKey, into locations: StoreLocations) throws -> EncryptedArchiveRestoreResult {
        try locations.validate()
        try requireEmptyOrAbsent(locations.mailFolder)
        try requireEmptyOrAbsent(locations.deviceFolder)
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        let (header, headerBytes) = try ArchiveFormat.readHeader(input)
        let key = try ArchiveFormat.unwrap(header, recovery: recoveryKey)

        let fileManager = FileManager.default
        let mailStaging = try stagingFolder(for: locations.mailFolder)
        let deviceStaging: URL
        do { deviceStaging = try stagingFolder(for: locations.deviceFolder) } catch {
            try? fileManager.removeItem(at: mailStaging)
            throw error
        }
        do {
            let reader = ArchivePayloadReader(opener: ArchiveOpener(input: input, key: key, headerDigest: Data(SHA256.hash(data: headerBytes)),
                                                                    chunkSize: header.chunkSize))
            guard try reader.read(ArchivePayload.magic.count) == ArchivePayload.magic else { throw EncryptedArchiveError.damaged }
            var result = EncryptedArchiveRestoreResult(messages: 0, files: 0, bytes: 0)
            var seen = Set<String>()
            while true {
                let tag = try reader.read(1)[0]
                if tag == ArchivePayload.endTag {
                    guard try reader.read(8).bigEndianUInt64 == UInt64(result.files), try reader.isAtEnd() else { throw EncryptedArchiveError.damaged }
                    break
                }
                guard tag == ArchivePayload.fileTag else { throw EncryptedArchiveError.damaged }
                let length = Int(try reader.read(2).bigEndianUInt16)
                guard (1...ArchivePayload.maximumPathLength).contains(length),
                      let path = String(data: try reader.read(length), encoding: .utf8) else { throw EncryptedArchiveError.damaged }
                let destination = try restoredURL(path, mail: mailStaging, device: deviceStaging)
                guard seen.insert(path).inserted else { throw EncryptedArchiveError.damaged }
                let size = try reader.read(8).bigEndianUInt64
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
                guard descriptor >= 0 else { throw MailStoreError.io(operation: "open", path: path, code: errno) }
                let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                let digest: Data
                do {
                    digest = try reader.stream(size) { try output.write(contentsOf: $0) }
                } catch {
                    try? output.close() // the error that stopped the restore is the one reported
                    throw error
                }
                try output.close()
                guard try reader.read(32) == digest else { throw EncryptedArchiveError.damaged }
                result.files += 1
                result.bytes += Int64(size)
                if isMessageOriginal(path) { result.messages += 1 }
            }
            try moveIntoPlace(mailStaging, locations.mailFolder)
            try moveIntoPlace(deviceStaging, locations.deviceFolder)
            return result
        } catch {
            try? fileManager.removeItem(at: mailStaging)
            try? fileManager.removeItem(at: deviceStaging)
            throw error
        }
    }

    // MARK: Writing

    static func write(locations: StoreLocations, to destination: URL, name: String?, now: Date, recoveryKey: ArchiveRecoveryKey,
                      chunkSize: Int, partial: [MailMessageID]) throws -> EncryptedArchiveResult {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EncryptedArchiveError.destinationUnavailable(destination.lastPathComponent)
        }
        let base = SafePath.displayFileName(name ?? defaultName(now))
        var target = destination.appendingPathComponent("\(base).\(fileExtension)")
        var counter = 2
        while fileManager.fileExists(atPath: target.path) {
            target = destination.appendingPathComponent("\(base) \(counter).\(fileExtension)")
            counter += 1
        }
        let staging = destination.appendingPathComponent(".\(base).\(UUID().uuidString.prefix(8).lowercased())\(AtomicWriter.partialSuffix)")
        guard fileManager.createFile(atPath: staging.path, contents: nil) else {
            throw EncryptedArchiveError.destinationUnavailable(destination.lastPathComponent)
        }
        var output: FileHandle?
        do {
            let handle = try FileHandle(forWritingTo: staging)
            output = handle
            let archiveKey = SymmetricKey(size: .bits256)
            let archiveID = ArchiveFormat.randomBytes(16)
            let header = ArchiveHeader(format: ArchiveHeader.currentFormat, archive: archiveID.base64EncodedString(),
                                       created: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)),
                                       cipher: ArchiveHeader.cipherName, chunkSize: chunkSize,
                                       keys: [try ArchiveFormat.recoverySlot(for: archiveKey, recovery: recoveryKey, archive: archiveID)])
            let headerBytes = try ArchiveFormat.headerEncoder.encode(header)
            var start = ArchiveFormat.magic
            start.append(bigEndian: UInt32(headerBytes.count))
            start.append(headerBytes)
            try handle.write(contentsOf: start)

            let payload = try ArchivePayloadWriter(sealer: ArchiveSealer(output: handle, key: archiveKey,
                                                                         headerDigest: Data(SHA256.hash(data: headerBytes)), chunkSize: chunkSize))
            var result = EncryptedArchiveResult(file: target, recoveryKey: recoveryKey, messages: 0, attachments: 0, files: 0, bytes: 0,
                                                failed: [], partial: partial)
            try addMailFolder(locations.mailFolder, to: payload, result: &result)
            let metadata = locations.deviceFolder.appendingPathComponent("metadata", isDirectory: true)
            for file in deviceMetadataFiles {
                guard let handle = try? FileHandle(forReadingFrom: metadata.appendingPathComponent(file)) else { continue }
                defer { try? handle.close() }
                try payload.add(path: "device/metadata/\(file)", from: handle, size: try handle.seekToEnd())
            }
            try payload.finish()
            result.files = payload.files
            result.bytes = payload.bytes
            try handle.synchronize()
            output = nil
            try handle.close()
            try fileManager.moveItem(at: staging, to: target)
            return result
        } catch {
            try? output?.close() // the error that stopped the archive is the one reported
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// Every file of the mail folder, sorted, hidden ones (temporary writes, `.DS_Store`) left out.
    /// An original goes in with its Markdown only when it matches the hash the Markdown recorded.
    private static func addMailFolder(_ mailFolder: URL, to payload: ArchivePayloadWriter, result: inout EncryptedArchiveResult) throws {
        let files = try regularFiles(under: mailFolder)
        let present = Set(files)
        for relative in files {
            let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
            let isMessageFile = parts.count >= 4 && parts[0] == "accounts" && parts[2] == "messages"
            // A message's Markdown goes in with its original, below; one without an original is
            // an interrupted write the store would remove.
            if isMessageFile && relative.hasSuffix(".md") { continue }
            guard let handle = try? FileHandle(forReadingFrom: mailFolder.appendingPathComponent(relative)) else { continue } // removed meanwhile
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            guard isMessageFile && relative.hasSuffix(".eml") else {
                try payload.add(path: "mail/\(relative)", from: handle, size: size)
                if parts.first == "blobs" { result.attachments += 1 }
                continue
            }
            let markdownPath = String(relative.dropLast(4)) + ".md"
            let markdown = present.contains(markdownPath) ? try? Data(contentsOf: mailFolder.appendingPathComponent(markdownPath)) : nil
            if let markdown, let front = try? DerivedMarkdown.frontMatter(of: String(decoding: markdown, as: UTF8.self)) {
                guard try sha256Hex(of: handle) == front.emlSha256 else {
                    if let id = MailMessageID(String(parts.last!.dropLast(4))) { result.failed.append(id) }
                    continue
                }
                try payload.add(path: "mail/\(relative)", from: handle, size: size)
                try payload.add(path: "mail/\(markdownPath)", data: markdown)
            } else {
                // No readable Markdown: the original is what matters, and the store derives the
                // Markdown again when the restored folder is opened.
                try payload.add(path: "mail/\(relative)", from: handle, size: size)
            }
            result.messages += 1
        }
    }

    private static func regularFiles(under root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            throw EncryptedArchiveError.destinationUnavailable(root.lastPathComponent)
        }
        var files: [String] = []
        while let relative = enumerator.nextObject() as? String {
            let type = enumerator.fileAttributes?[.type] as? FileAttributeType
            if (relative as NSString).lastPathComponent.hasPrefix(".") {
                if type == .typeDirectory { enumerator.skipDescendants() }
                continue
            }
            // Symbolic links are never followed: whatever they point at is not the person's mail.
            if type == .typeRegular { files.append(relative) }
        }
        return files.sorted()
    }

    private static func sha256Hex(of handle: FileHandle) throws -> String {
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        while let piece = try handle.read(upToCount: ArchivePayload.pieceSize), !piece.isEmpty {
            hasher.update(data: piece)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func defaultName(_ now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Mail Archive \(formatter.string(from: now))"
    }

    // MARK: Restoring

    /// Where an archived path lands: `mail/…` in the mail folder, `device/metadata/<known file>`
    /// in the device folder. Anything else, and any `..`, hidden or empty segment, is refused.
    static func restoredURL(_ path: String, mail: URL, device: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.count <= 16,
              parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\0") && $0.utf8.count <= 255 }) else {
            throw EncryptedArchiveError.unsafePath(path)
        }
        let url: URL
        let root: URL
        if parts[0] == "mail" {
            root = mail
            url = parts.dropFirst().reduce(mail) { $0.appendingPathComponent($1) }
        } else if parts.count == 3, parts[0] == "device", parts[1] == "metadata", deviceMetadataFiles.contains(parts[2]) {
            root = device
            url = device.appendingPathComponent("metadata", isDirectory: true).appendingPathComponent(parts[2])
        } else {
            throw EncryptedArchiveError.unsafePath(path)
        }
        guard SafePath.isContained(url, in: root) else { throw EncryptedArchiveError.unsafePath(path) }
        return url
    }

    private static func isMessageOriginal(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.count >= 5 && parts[1] == "accounts" && parts[3] == "messages" && path.hasSuffix(".eml")
    }

    private static func requireEmptyOrAbsent(_ folder: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue,
              try fileManager.contentsOfDirectory(atPath: folder.path).allSatisfy({ $0 == ".DS_Store" }) else {
            throw EncryptedArchiveError.destinationNotEmpty(folder.lastPathComponent)
        }
    }

    private static func stagingFolder(for folder: URL) throws -> URL {
        let parent = folder.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".\(folder.lastPathComponent).restore-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw EncryptedArchiveError.destinationUnavailable(parent.lastPathComponent)
        }
        return staging
    }

    private static func moveIntoPlace(_ staging: URL, _ folder: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: folder.path) { try fileManager.removeItem(at: folder) }
        try fileManager.moveItem(at: staging, to: folder)
    }
}
