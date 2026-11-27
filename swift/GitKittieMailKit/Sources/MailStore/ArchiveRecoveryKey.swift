import CryptoKit
import Foundation

/// The key that opens an encrypted archive (GKM-032, MAIL-129): 128 random bits, shown once as
/// 28 characters in seven groups of four, `7K2M-QX4R-…`. Crockford base32 (no I, L, O or U), so
/// it reads aloud and types without mix-ups; the last two characters are a check over the
/// key, so a typo is caught as a typo instead of looking like the wrong key.
///
/// It is never stored by the app and never printed by `description`: whoever has it, and the
/// archive, has the mail.
public struct ArchiveRecoveryKey: Sendable, Equatable, CustomStringConvertible {
    static let byteCount = 16
    /// 26 symbols carry the 128 key bits (and two zero bits), two more the check.
    static let symbolCount = 28
    static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    let bytes: [UInt8]

    init(bytes: [UInt8]) {
        precondition(bytes.count == Self.byteCount, "a recovery key is 16 bytes")
        self.bytes = bytes
    }

    /// A new key from the system's secure random source.
    public static func generate() -> ArchiveRecoveryKey {
        let key = SymmetricKey(size: SymmetricKeySize(bitCount: byteCount * 8))
        return ArchiveRecoveryKey(bytes: key.withUnsafeBytes { Array($0) })
    }

    /// Reads a key as a person typed it: any case, with or without dashes and spaces; `O` is
    /// read as zero and `I` and `L` as one, as Crockford base32 does.
    public init(_ text: String) throws {
        var values: [UInt8] = []
        for character in text.uppercased() {
            if character == "-" || character.isWhitespace { continue }
            let mapped: Character = switch character {
            case "O": "0"
            case "I", "L": "1"
            default: character
            }
            guard let value = Self.alphabet.firstIndex(of: mapped) else { throw EncryptedArchiveError.malformedRecoveryKey }
            values.append(UInt8(value))
        }
        guard values.count == Self.symbolCount else { throw EncryptedArchiveError.malformedRecoveryKey }
        var bytes: [UInt8] = []
        var accumulator: UInt32 = 0
        var bits = 0
        for value in values.prefix(26) {
            accumulator = (accumulator << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bits - 8)))
                bits -= 8
                accumulator &= (1 << UInt32(bits)) - 1
            }
        }
        // 130 bits read, 128 used: the two left over are always zero in a key we made.
        guard bytes.count == Self.byteCount, accumulator == 0 else { throw EncryptedArchiveError.malformedRecoveryKey }
        let key = ArchiveRecoveryKey(bytes: bytes)
        guard Array(values.suffix(2)) == key.checkSymbols else { throw EncryptedArchiveError.malformedRecoveryKey }
        self = key
    }

    /// The key as it is shown and saved: seven groups of four, joined by dashes.
    public var text: String { groups.joined(separator: "-") }

    /// The seven groups of four.
    public var groups: [String] {
        let symbols = String(symbolValues.map { Self.alphabet[Int($0)] })
        return stride(from: 0, to: symbols.count, by: 4).map {
            let start = symbols.index(symbols.startIndex, offsetBy: $0)
            return String(symbols[start..<symbols.index(start, offsetBy: 4)])
        }
    }

    /// Never the key itself, so a log line or a debugger print can't leak it.
    public var description: String { "ArchiveRecoveryKey(hidden)" }

    private var symbolValues: [UInt8] {
        var values: [UInt8] = []
        var accumulator: UInt32 = 0
        var bits = 0
        for byte in bytes {
            accumulator = (accumulator << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                values.append(UInt8((accumulator >> UInt32(bits - 5)) & 31))
                bits -= 5
            }
            accumulator &= (1 << UInt32(bits)) - 1
        }
        values.append(UInt8((accumulator << UInt32(5 - bits)) & 31))
        return values + checkSymbols
    }

    /// Ten bits of SHA-256 over the key, as two symbols.
    private var checkSymbols: [UInt8] {
        let digest = Array(SHA256.hash(data: bytes))
        let check = (UInt16(digest[0]) << 2) | (UInt16(digest[1]) >> 6)
        return [UInt8((check >> 5) & 31), UInt8(check & 31)]
    }

    var symmetricKey: SymmetricKey { SymmetricKey(data: bytes) }
}
