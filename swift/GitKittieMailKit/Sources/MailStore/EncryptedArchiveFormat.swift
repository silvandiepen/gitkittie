import CryptoKit
import Foundation

// The encrypted archive container (GKM-032, MAIL-128; format in Architecture.md, "Encrypted
// archive"). CryptoKit only: AES-256-GCM for the data and for wrapping the archive key, HKDF-SHA256
// to turn the recovery key into a wrapping key, SHA-256 for the header digest and file checks.
//
//     "GKMARCH1"                       8 bytes, magic
//     UInt32 big-endian n              header length, at most 64 KiB
//     header                           n bytes of JSON (ArchiveHeader), not encrypted, authenticated
//     record*                          UInt32 big-endian length (top bit: final record), then an
//                                      AES-GCM sealed box: 12-byte nonce, ciphertext, 16-byte tag
//
// Every record is sealed with the archive key and authenticates "gkm-archive-v1 chunk",
// SHA-256 of the header bytes, its index (UInt64) and whether it is the final one. A changed
// header, a changed, moved, repeated or dropped record, a missing end and bytes after the end all
// fail to open. The plaintext records carry the payload (ArchivePayload) in pieces of at most
// `chunkSize` bytes, so neither side ever holds more than one record of a multi-gigabyte mailbox.

/// What can go wrong with an encrypted archive. Messages say what happened, never what is in it.
public enum EncryptedArchiveError: Error, Equatable, CustomStringConvertible {
    /// Not a GitKittie Mail archive at all.
    case notAnArchive
    /// Written by a newer version of the app.
    case unsupportedFormat(Int)
    /// The recovery key has the wrong length, a character that can't be in one, or a typo.
    case malformedRecoveryKey
    /// A well-formed key that doesn't open this archive.
    case wrongKey
    /// The archive was changed or damaged after it was written: a record or the header fails
    /// its check, records are out of order, or there are bytes after the end.
    case damaged
    /// The archive ends before its last record: an interrupted copy or a cut file.
    case truncated
    /// A path in the archive that would land outside the restored folders.
    case unsafePath(String)
    /// The folder to restore into already has files in it.
    case destinationNotEmpty(String)
    /// A folder that can't be written to.
    case destinationUnavailable(String)

    public var description: String {
        switch self {
        case .notAnArchive: return "This file isn’t a GitKittie Mail archive."
        case .unsupportedFormat(let version): return "This archive was made by a newer version of GitKittie Mail (format \(version))."
        case .malformedRecoveryKey: return "That isn’t a recovery key: check it for a typo. It has 28 letters and digits in groups of four."
        case .wrongKey: return "This recovery key doesn’t open this archive."
        case .damaged: return "The archive has been changed or damaged since it was made, so it can’t be trusted. Nothing was restored."
        case .truncated: return "The archive is incomplete: it ends early. Copy it again from where it was saved. Nothing was restored."
        case .unsafePath(let path): return "The archive holds a file that would land outside the restored folder (\(path.debugDescription)). Nothing was restored."
        case .destinationNotEmpty(let name): return "“\(name)” already has files in it; restore into a new folder."
        case .destinationUnavailable(let name): return "Can’t write to “\(name)”."
        }
    }
}

/// The plaintext header: what an archive is and how its key is wrapped. Nothing from the mail.
struct ArchiveHeader: Codable, Equatable {
    static let currentFormat = 1
    static let cipherName = "AES-256-GCM"

    var format: Int
    /// 16 random bytes, base64: binds each key slot to this archive.
    var archive: String
    var created: Date
    var cipher: String
    /// The largest plaintext record.
    var chunkSize: Int
    /// The archive key, wrapped once per way of opening it. Format 1 has one kind, "recovery".
    var keys: [ArchiveKeySlot]
}

/// The archive key wrapped by a key derived from the recovery key.
struct ArchiveKeySlot: Codable, Equatable {
    static let recoveryKind = "recovery"
    static let hkdfName = "HKDF-SHA256"

    var kind: String
    var kdf: String
    /// 32 random bytes, base64.
    var salt: String
    /// AES-GCM sealed box (nonce, the 32-byte archive key encrypted, tag), base64.
    var wrapped: String
}

enum ArchiveFormat {
    static let magic = Data("GKMARCH1".utf8)
    static let maximumHeaderLength = 64 * 1024
    static let defaultChunkSize = 1 << 20
    /// What a header may ask for: bounded, so a hostile header can't make a reader allocate much.
    static let chunkSizes = 4 * 1024...(16 << 20)
    /// AES-GCM's nonce and tag around each record's ciphertext.
    static let sealOverhead = 12 + 16
    static let finalFlag: UInt32 = 0x8000_0000

    static let fileExtension = "gkmarchive"

    // MARK: Keys

    static func wrappingKey(_ recovery: ArchiveRecoveryKey, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: recovery.symmetricKey, salt: salt,
                               info: Data("gkm-archive-v1 recovery key".utf8), outputByteCount: 32)
    }

    static func slotContext(archive: Data) -> Data { Data("gkm-archive-v1 key slot".utf8) + archive }

    static func recoverySlot(for archiveKey: SymmetricKey, recovery: ArchiveRecoveryKey, archive: Data) throws -> ArchiveKeySlot {
        let salt = randomBytes(32)
        let sealed = try AES.GCM.seal(archiveKey.withUnsafeBytes { Data($0) }, using: wrappingKey(recovery, salt: salt),
                                      authenticating: slotContext(archive: archive))
        guard let combined = sealed.combined else { throw EncryptedArchiveError.damaged }
        return ArchiveKeySlot(kind: ArchiveKeySlot.recoveryKind, kdf: ArchiveKeySlot.hkdfName,
                              salt: salt.base64EncodedString(), wrapped: combined.base64EncodedString())
    }

    /// The archive key, if `recovery` opens one of the header's recovery slots.
    static func unwrap(_ header: ArchiveHeader, recovery: ArchiveRecoveryKey) throws -> SymmetricKey {
        guard let archive = Data(base64Encoded: header.archive) else { throw EncryptedArchiveError.damaged }
        for slot in header.keys where slot.kind == ArchiveKeySlot.recoveryKind && slot.kdf == ArchiveKeySlot.hkdfName {
            guard let salt = Data(base64Encoded: slot.salt), let wrapped = Data(base64Encoded: slot.wrapped),
                  let box = try? AES.GCM.SealedBox(combined: wrapped) else { throw EncryptedArchiveError.damaged }
            if let key = try? AES.GCM.open(box, using: wrappingKey(recovery, salt: salt), authenticating: slotContext(archive: archive)),
               key.count == 32 {
                return SymmetricKey(data: key)
            }
        }
        throw EncryptedArchiveError.wrongKey
    }

    static func randomBytes(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    // MARK: Records

    static func recordContext(headerDigest: Data, index: UInt64, final: Bool) -> Data {
        var context = Data("gkm-archive-v1 chunk".utf8)
        context.append(headerDigest)
        context.append(bigEndian: index)
        context.append(final ? 1 : 0)
        return context
    }

    // MARK: Header

    static let headerEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let headerDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Reads the magic and the header. Returns the header and the exact bytes it was read from,
    /// whose digest every record authenticates.
    static func readHeader(_ input: FileHandle) throws -> (header: ArchiveHeader, bytes: Data) {
        // A file shorter than the magic is not an archive either.
        guard let magic = try? input.readExactly(Self.magic.count), magic == Self.magic else { throw EncryptedArchiveError.notAnArchive }
        guard let lengthBytes = try input.readExactly(4) else { throw EncryptedArchiveError.truncated }
        let length = Int(lengthBytes.bigEndianUInt32)
        guard length > 0, length <= maximumHeaderLength else { throw EncryptedArchiveError.damaged }
        guard let bytes = try input.readExactly(length) else { throw EncryptedArchiveError.truncated }
        struct Version: Decodable { var format: Int }
        guard let version = try? headerDecoder.decode(Version.self, from: bytes) else { throw EncryptedArchiveError.damaged }
        guard version.format == ArchiveHeader.currentFormat else { throw EncryptedArchiveError.unsupportedFormat(version.format) }
        guard let header = try? headerDecoder.decode(ArchiveHeader.self, from: bytes),
              header.cipher == ArchiveHeader.cipherName, chunkSizes.contains(header.chunkSize) else { throw EncryptedArchiveError.damaged }
        return (header, bytes)
    }
}

/// Seals plaintext into records as it arrives; `finish()` seals the last one.
final class ArchiveSealer {
    private let output: FileHandle
    private let key: SymmetricKey
    private let headerDigest: Data
    private let chunkSize: Int
    private var buffer = Data()
    private var index: UInt64 = 0

    init(output: FileHandle, key: SymmetricKey, headerDigest: Data, chunkSize: Int) {
        self.output = output
        self.key = key
        self.headerDigest = headerDigest
        self.chunkSize = chunkSize
    }

    func append(_ data: Data) throws {
        buffer.append(data)
        // Strictly more than a record: what is left when the payload ends is the final record,
        // so the final record is never one that was already sealed as not final.
        while buffer.count > chunkSize {
            try seal(Data(buffer.prefix(chunkSize)), final: false)
            buffer = Data(buffer.dropFirst(chunkSize))
        }
    }

    func finish() throws {
        try seal(buffer, final: true)
        buffer = Data()
    }

    private func seal(_ plaintext: Data, final: Bool) throws {
        let box = try AES.GCM.seal(plaintext, using: key,
                                   authenticating: ArchiveFormat.recordContext(headerDigest: headerDigest, index: index, final: final))
        guard let combined = box.combined else { throw EncryptedArchiveError.damaged }
        var record = Data()
        record.append(bigEndian: UInt32(combined.count) | (final ? ArchiveFormat.finalFlag : 0))
        record.append(combined)
        try output.write(contentsOf: record)
        index += 1
    }
}

/// Opens records one by one, in order, and checks the end.
final class ArchiveOpener {
    private let input: FileHandle
    private let key: SymmetricKey
    private let headerDigest: Data
    private let chunkSize: Int
    private var index: UInt64 = 0
    private var ended = false

    init(input: FileHandle, key: SymmetricKey, headerDigest: Data, chunkSize: Int) {
        self.input = input
        self.key = key
        self.headerDigest = headerDigest
        self.chunkSize = chunkSize
    }

    /// The next record's plaintext; nil once the final record has been read and nothing follows it.
    func next() throws -> Data? {
        if ended { return nil }
        guard let prefix = try input.readExactly(4) else { throw EncryptedArchiveError.truncated }
        let raw = prefix.bigEndianUInt32
        let final = raw & ArchiveFormat.finalFlag != 0
        let length = Int(raw & ~ArchiveFormat.finalFlag)
        guard length >= ArchiveFormat.sealOverhead, length <= chunkSize + ArchiveFormat.sealOverhead else { throw EncryptedArchiveError.damaged }
        guard let sealed = try input.readExactly(length) else { throw EncryptedArchiveError.truncated }
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plaintext = try? AES.GCM.open(box, using: key,
                                                authenticating: ArchiveFormat.recordContext(headerDigest: headerDigest, index: index, final: final))
        else { throw EncryptedArchiveError.damaged }
        index += 1
        if final {
            ended = true
            if let extra = try input.read(upToCount: 1), !extra.isEmpty { throw EncryptedArchiveError.damaged }
        }
        return plaintext
    }
}

// MARK: - Payload

/// The plaintext inside the records: a magic, then entries.
///
///     "GKMP" 0x01
///     file:  0x46 'F', UInt16 path length, UTF-8 path, UInt64 size, the bytes, SHA-256 of the bytes
///     end:   0x45 'E', UInt64 number of files
///
/// Paths are `mail/<path in the mail folder>` or `device/metadata/<file>` (MAIL-128).
enum ArchivePayload {
    static let magic = Data("GKMP".utf8) + Data([1])
    static let fileTag: UInt8 = 0x46
    static let endTag: UInt8 = 0x45
    static let maximumPathLength = 1024
    static let pieceSize = 1 << 20
}

/// Writes payload entries into a sealer, streaming each file.
final class ArchivePayloadWriter {
    private let sealer: ArchiveSealer
    private(set) var files = 0
    private(set) var bytes: Int64 = 0

    init(sealer: ArchiveSealer) throws {
        self.sealer = sealer
        try sealer.append(ArchivePayload.magic)
    }

    func add(path: String, data: Data) throws {
        try begin(path: path, size: UInt64(data.count))
        try sealer.append(data)
        try end(digest: Data(SHA256.hash(data: data)), size: Int64(data.count))
    }

    /// Streams `size` bytes from the start of `handle`'s file.
    func add(path: String, from handle: FileHandle, size: UInt64) throws {
        try begin(path: path, size: size)
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        var remaining = size
        while remaining > 0 {
            guard let piece = try handle.read(upToCount: Int(min(UInt64(ArchivePayload.pieceSize), remaining))), !piece.isEmpty else {
                // The file shrank under us; an entry can't be shortened once its size is written.
                throw MailStoreError.io(operation: "read", path: path, code: EIO)
            }
            hasher.update(data: piece)
            try sealer.append(piece)
            remaining -= UInt64(piece.count)
        }
        try end(digest: Data(hasher.finalize()), size: Int64(size))
    }

    func finish() throws {
        var end = Data([ArchivePayload.endTag])
        end.append(bigEndian: UInt64(files))
        try sealer.append(end)
        try sealer.finish()
    }

    private func begin(path: String, size: UInt64) throws {
        let pathBytes = Data(path.utf8)
        guard !pathBytes.isEmpty, pathBytes.count <= ArchivePayload.maximumPathLength else { throw EncryptedArchiveError.unsafePath(path) }
        var entry = Data([ArchivePayload.fileTag])
        entry.append(bigEndian: UInt16(pathBytes.count))
        entry.append(pathBytes)
        entry.append(bigEndian: size)
        try sealer.append(entry)
    }

    private func end(digest: Data, size: Int64) throws {
        try sealer.append(digest)
        files += 1
        bytes += size
    }
}

/// Reads payload bytes across records without copying a record per read.
final class ArchivePayloadReader {
    private let opener: ArchiveOpener
    private var record = Data()
    private var offset = 0

    init(opener: ArchiveOpener) {
        self.opener = opener
    }

    /// Exactly `count` bytes. Every record has passed its check, so running out here means the
    /// payload itself is malformed.
    func read(_ count: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            try fill()
            let take = min(count - result.count, record.count - offset)
            result.append(record[record.startIndex + offset ..< record.startIndex + offset + take])
            offset += take
        }
        return result
    }

    /// Streams `count` bytes to `write`, returning their SHA-256.
    func stream(_ count: UInt64, to write: (Data) throws -> Void) throws -> Data {
        var hasher = SHA256()
        var remaining = count
        while remaining > 0 {
            try fill()
            let take = Int(min(remaining, UInt64(record.count - offset)))
            let piece = record[record.startIndex + offset ..< record.startIndex + offset + take]
            hasher.update(data: piece)
            try write(Data(piece))
            offset += take
            remaining -= UInt64(take)
        }
        return Data(hasher.finalize())
    }

    /// True when every record has been read and nothing is left in them.
    func isAtEnd() throws -> Bool {
        while offset == record.count {
            guard let next = try opener.next() else { return true }
            record = next
            offset = 0
        }
        return false
    }

    private func fill() throws {
        while offset == record.count {
            guard let next = try opener.next() else { throw EncryptedArchiveError.damaged }
            record = next
            offset = 0
        }
    }
}

// MARK: - Bytes

extension Data {
    mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    var bigEndianUInt32: UInt32 { reduce(0) { ($0 << 8) | UInt32($1) } }
    var bigEndianUInt16: UInt16 { reduce(0) { ($0 << 8) | UInt16($1) } }
    var bigEndianUInt64: UInt64 { reduce(0) { ($0 << 8) | UInt64($1) } }
}

extension FileHandle {
    /// Exactly `count` bytes; nil at the end of the file before any byte; `truncated` when the
    /// file ends part way.
    func readExactly(_ count: Int) throws -> Data? {
        var result = Data()
        while result.count < count {
            guard let piece = try read(upToCount: count - result.count), !piece.isEmpty else {
                if result.isEmpty { return nil }
                throw EncryptedArchiveError.truncated
            }
            result.append(piece)
        }
        return result
    }
}
