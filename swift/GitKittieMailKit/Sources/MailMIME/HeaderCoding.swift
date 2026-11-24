import Foundation

/// Text encodings by IANA charset name, with the aliases mail actually uses.
public enum Charsets {
    public static func encoding(named name: String) -> String.Encoding? {
        let lowered = name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
        switch lowered {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii", "ansi_x3.4-1968": return .ascii
        case "iso-8859-1", "latin1", "iso8859-1": return .isoLatin1
        default: break
        }
        let cf = CFStringConvertIANACharSetNameToEncoding(lowered as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// Decodes bytes in `charset`, falling back to UTF-8 and then Latin-1 (which never fails),
    /// so a wrong or missing label degrades to odd characters, never to lost text.
    public static func decode(_ bytes: Data, charset: String?) -> String {
        if let charset, let encoding = encoding(named: charset), let text = String(data: bytes, encoding: encoding) {
            return text
        }
        if let text = String(data: bytes, encoding: .utf8) { return text }
        return String(data: bytes, encoding: .isoLatin1) ?? ""
    }
}

/// Content-Transfer-Encoding (RFC 2045 6).
public enum TransferEncoding {
    /// Lenient base64: ignores whitespace and anything outside the alphabet, tolerates missing
    /// padding.
    public static func decodeBase64(_ data: Data) -> Data {
        var cleaned = [UInt8]()
        cleaned.reserveCapacity(data.count)
        for byte in data {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "/"):
                cleaned.append(byte)
            default: continue
            }
        }
        while cleaned.count % 4 != 0 {
            if cleaned.count % 4 == 1 { cleaned.removeLast() } else { cleaned.append(UInt8(ascii: "=")) }
        }
        return Data(base64Encoded: Data(cleaned)) ?? Data()
    }

    /// Quoted-printable (RFC 2045 6.7), lenient: an invalid escape is kept as is.
    public static func decodeQuotedPrintable(_ data: Data, isHeader: Bool = false) -> Data {
        let bytes = [UInt8](data)
        var out = Data(capacity: bytes.count)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if isHeader && byte == UInt8(ascii: "_") {
                out.append(0x20)
                i += 1
            } else if byte == UInt8(ascii: "=") {
                // Soft line break: "=" then optional whitespace then CRLF or LF.
                var j = i + 1
                while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 }
                if j < bytes.count, bytes[j] == 0x0D || bytes[j] == 0x0A {
                    if bytes[j] == 0x0D, j + 1 < bytes.count, bytes[j + 1] == 0x0A { j += 1 }
                    i = j + 1
                } else if j == bytes.count {
                    i = j
                } else if i + 2 < bytes.count, let high = hex(bytes[i + 1]), let low = hex(bytes[i + 2]) {
                    out.append(high << 4 | low)
                    i += 3
                } else {
                    out.append(byte)
                    i += 1
                }
            } else {
                out.append(byte)
                i += 1
            }
        }
        return out
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }

    /// Base64 in lines of 76 characters, CRLF-terminated.
    public static func encodeBase64Lines(_ data: Data) -> String {
        let encoded = data.base64EncodedString()
        var lines: [Substring] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: 76, limitedBy: encoded.endIndex) ?? encoded.endIndex
            lines.append(encoded[index..<end])
            index = end
        }
        return lines.joined(separator: "\r\n") + (lines.isEmpty ? "" : "\r\n")
    }

    /// Quoted-printable for a text body, lines at most 76 characters, CRLF line breaks.
    public static func encodeQuotedPrintable(_ text: String) -> String {
        var output = ""
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for (lineIndex, line) in lines.enumerated() {
            var current = ""
            let bytes = Array(line.utf8)
            for (i, byte) in bytes.enumerated() {
                let isLast = i == bytes.count - 1
                let token: String
                switch byte {
                case UInt8(ascii: "="): token = "=3D"
                case 0x20 where isLast, 0x09 where isLast: token = String(format: "=%02X", byte)
                case 0x21...0x7E, 0x20, 0x09: token = String(UnicodeScalar(byte))
                default: token = String(format: "=%02X", byte)
                }
                // A leading "." is encoded too, so the body is safe even without dot-stuffing.
                let safeToken = (current.isEmpty && byte == UInt8(ascii: ".")) ? "=2E" : token
                if current.utf8.count + safeToken.utf8.count > 75 {
                    output += current + "=\r\n"
                    current = ""
                }
                current += safeToken
            }
            output += current
            if lineIndex < lines.count - 1 { output += "\r\n" }
        }
        return output
    }
}

/// RFC 2047 encoded words in header values.
public enum EncodedWords {
    /// Decodes every `=?charset?B|Q?text?=` in `value`. Whitespace between two adjacent encoded
    /// words is dropped (RFC 2047 6.2); a malformed word stays as written.
    public static func decode(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        var result = ""
        var remaining = Substring(value)
        var lastWasEncoded = false
        var pendingWhitespace = ""
        while !remaining.isEmpty {
            if remaining.hasPrefix("=?"), let (decoded, rest) = decodeWord(remaining) {
                if !lastWasEncoded { result += pendingWhitespace }
                pendingWhitespace = ""
                result += decoded
                remaining = rest
                lastWasEncoded = true
                continue
            }
            let character = remaining.removeFirst()
            if character == " " || character == "\t" || character == "\r" || character == "\n" {
                if character == " " || character == "\t" { pendingWhitespace.append(character) }
                continue
            }
            result += pendingWhitespace
            pendingWhitespace = ""
            result.append(character)
            lastWasEncoded = false
        }
        return result + (lastWasEncoded ? "" : pendingWhitespace)
    }

    private static func decodeWord(_ text: Substring) -> (String, Substring)? {
        // =?charset?encoding?encoded-text?=
        let body = text.dropFirst(2)
        guard let q1 = body.firstIndex(of: "?") else { return nil }
        let charsetField = body[body.startIndex..<q1]
        let afterCharset = body[body.index(after: q1)...]
        guard let q2 = afterCharset.firstIndex(of: "?") else { return nil }
        let encoding = afterCharset[afterCharset.startIndex..<q2].uppercased()
        let afterEncoding = afterCharset[afterCharset.index(after: q2)...]
        guard let end = afterEncoding.range(of: "?=") else { return nil }
        let encodedText = afterEncoding[afterEncoding.startIndex..<end.lowerBound]
        guard !encodedText.contains(" "), charsetField.count < 64 else { return nil }
        // RFC 2231 adds an optional language: charset*language.
        let charset = String(charsetField.split(separator: "*", maxSplits: 1).first ?? "")
        let bytes: Data
        switch encoding {
        case "B": bytes = TransferEncoding.decodeBase64(Data(encodedText.utf8))
        case "Q": bytes = TransferEncoding.decodeQuotedPrintable(Data(encodedText.utf8), isHeader: true)
        default: return nil
        }
        return (Charsets.decode(bytes, charset: charset), afterEncoding[end.upperBound...])
    }

    /// Encodes `value` for a header if it has non-ASCII characters: UTF-8 base64 encoded words,
    /// each at most 75 characters, never splitting a character.
    public static func encodeIfNeeded(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { !$0.isASCII || $0.value < 0x20 }) else { return value }
        let prefix = "=?UTF-8?B?", suffix = "?="
        let maxPayloadBytes = ((75 - prefix.count - suffix.count) / 4) * 3
        var words: [String] = []
        var chunk = Data()
        for character in value {
            let bytes = Data(String(character).utf8)
            if chunk.count + bytes.count > maxPayloadBytes, !chunk.isEmpty {
                words.append(prefix + chunk.base64EncodedString() + suffix)
                chunk = Data()
            }
            chunk.append(bytes)
        }
        if !chunk.isEmpty { words.append(prefix + chunk.base64EncodedString() + suffix) }
        return words.joined(separator: "\r\n ")
    }
}

/// `value; name=param; name*=utf-8''%E2%82%AC` headers: Content-Type, Content-Disposition.
public struct ParameterizedValue: Sendable, Hashable {
    public var value: String
    /// Lower-cased names; RFC 2231 continuations and charsets already resolved.
    public var parameters: [String: String]

    public init(value: String, parameters: [String: String]) {
        self.value = value
        self.parameters = parameters
    }

    public static func parse(_ raw: String) -> ParameterizedValue {
        let parts = splitOutsideQuotes(raw, separator: ";")
        let value = (parts.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        var plain: [String: String] = [:]
        var extended: [String: [(index: Int, encoded: Bool, text: String)]] = [:]
        for part in parts.dropFirst() {
            guard let equals = part.firstIndex(of: "=") else { continue }
            var name = part[part.startIndex..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var text = part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
                text = unquote(String(text.dropFirst().dropLast()))
            }
            guard !name.isEmpty else { continue }
            // RFC 2231: name*=, name*0=, name*1*=
            let encoded = name.hasSuffix("*")
            if encoded { name.removeLast() }
            if let star = name.firstIndex(of: "*"), let index = Int(name[name.index(after: star)...]) {
                extended[String(name[name.startIndex..<star]), default: []].append((index, encoded, text))
            } else if encoded {
                extended[name, default: []].append((0, true, text))
            } else {
                plain[name] = text
            }
        }
        for (name, pieces) in extended {
            let sorted = pieces.sorted { $0.index < $1.index }
            var charset: String?
            var bytes = Data()
            for (offset, piece) in sorted.enumerated() {
                var text = Substring(piece.text)
                if piece.encoded {
                    if offset == 0 {
                        let fields = text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                        if fields.count == 3 {
                            charset = String(fields[0])
                            text = fields[2]
                        }
                    }
                    bytes.append(percentDecode(text))
                } else {
                    bytes.append(Data(text.utf8))
                }
            }
            plain[name] = Charsets.decode(bytes, charset: charset)
        }
        // A plain value may itself be an RFC 2047 word (widespread for filenames, though not
        // allowed by the RFC).
        for (name, text) in plain where text.contains("=?") {
            plain[name] = EncodedWords.decode(text)
        }
        return ParameterizedValue(value: value, parameters: plain)
    }

    private static func percentDecode(_ text: Substring) -> Data {
        var out = Data()
        var iterator = Array(text.utf8).makeIterator()
        while let byte = iterator.next() {
            if byte == UInt8(ascii: "%"), let h = iterator.next(), let l = iterator.next(),
               let value = UInt8(String(decoding: [h, l], as: UTF8.self), radix: 16) {
                out.append(value)
            } else {
                out.append(byte)
            }
        }
        return out
    }

    static func unquote(_ text: String) -> String {
        var out = ""
        var escaped = false
        for character in text {
            if escaped { out.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else { out.append(character) }
        }
        return out
    }

    static func splitOutsideQuotes(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in text {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" && inQuotes { current.append(character); escaped = true; continue }
            if character == "\"" { inQuotes.toggle() }
            if character == separator && !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    /// Writes `name="value"` or, for non-ASCII, RFC 2231 `name*=UTF-8''…`.
    public static func formatParameter(_ name: String, _ value: String) -> String {
        if value.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0 != "\"" && $0 != "\\" }) {
            return "\(name)=\"\(value)\""
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var encoded = ""
        for byte in value.utf8 {
            let scalar = Unicode.Scalar(byte)
            if byte < 0x80, allowed.contains(scalar) { encoded.append(Character(scalar)) }
            else { encoded += String(format: "%%%02X", byte) }
        }
        return "\(name)*=UTF-8''\(encoded)"
    }
}
