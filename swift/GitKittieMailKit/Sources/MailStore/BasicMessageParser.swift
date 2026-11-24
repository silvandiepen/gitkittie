import Foundation
import MailCore

/// PROVISIONAL: a small RFC 5322 / MIME reader, enough for the store to derive Markdown and an
/// index while GKM-002 picks the real MIME library. It handles header unfolding, RFC 2047
/// encoded words, address lists (quoted names, comments, groups), Message-ID lists, RFC 5322
/// dates, Content-Type / Content-Disposition parameters (with RFC 2231 continuations),
/// base64 and quoted-printable, charsets, and nested multiparts with depth and part limits.
///
/// It does not render HTML, does not verify signatures, does not decode TNEF or uuencode, and
/// does not try to repair badly broken structure: a part it cannot read is left out of the
/// Markdown, never out of the `.eml`, which is stored byte for byte whatever happens here.
public struct BasicMessageParser: MessageParsing {
    /// Deepest multipart nesting followed; deeper parts stay in the `.eml` only.
    public static let maximumDepth = 8
    /// Most leaf parts read from one message; a guard against part bombs.
    public static let maximumParts = 512

    public init() {}

    public func parse(_ data: Data) throws -> ParsedMessage {
        let bytes = [UInt8](data)
        let entity = try Entity(bytes[...], requireHeaders: true)
        let headers = entity.headers

        var message = ParsedMessage()
        message.messageID = headers.first("message-id").flatMap { MIME.messageIDs($0).first ?? MIME.trimmedNonEmpty($0) }
        message.inReplyTo = headers.first("in-reply-to").map(MIME.messageIDs) ?? []
        message.references = headers.first("references").map(MIME.messageIDs) ?? []
        message.from = headers.first("from").map(MIME.addresses) ?? []
        message.to = headers.all("to").flatMap(MIME.addresses)
        message.cc = headers.all("cc").flatMap(MIME.addresses)
        message.replyTo = headers.first("reply-to").map(MIME.addresses) ?? []
        message.subject = headers.first("subject").map { MIME.decodeEncodedWords($0).trimmingCharacters(in: .whitespaces) }
        message.date = headers.first("date").flatMap(MIME.date)

        var walker = Walker()
        walker.walk(entity, depth: 0)
        message.textBody = walker.text.isEmpty ? nil : walker.text.joined(separator: "\n\n")
        message.hasHTMLBody = walker.hasHTML
        message.attachments = walker.attachments
        return message
    }
}

// MARK: - Entities

/// One MIME entity: its header fields (unfolded, in order) and its raw body bytes.
struct Entity {
    var headers: HeaderFields
    var body: ArraySlice<UInt8>

    init(_ bytes: ArraySlice<UInt8>, requireHeaders: Bool) throws {
        var fields: [(String, String)] = []
        var index = bytes.startIndex
        var bodyStart = bytes.endIndex
        var current: (name: String, value: [UInt8])?

        while index < bytes.endIndex {
            let lineEnd = bytes[index...].firstIndex(of: 0x0A) ?? bytes.endIndex
            var line = bytes[index..<lineEnd]
            if line.last == 0x0D { line = line.dropLast() }
            let next = lineEnd < bytes.endIndex ? lineEnd + 1 : lineEnd
            if line.isEmpty {
                bodyStart = next
                break
            }
            if line.first == 0x20 || line.first == 0x09 {
                // A folded continuation of the field above (RFC 5322, 2.2.3).
                current?.value.append(contentsOf: line)
            } else if let colon = line.firstIndex(of: 0x3A), colon > line.startIndex,
                      line[line.startIndex..<colon].allSatisfy({ $0 > 0x20 && $0 < 0x7F }) {
                if let field = current { fields.append((field.name, MIME.headerString(field.value))) }
                let name = String(decoding: line[line.startIndex..<colon], as: UTF8.self).lowercased()
                current = (name, Array(line[(colon + 1)...]))
            } else if fields.isEmpty && current == nil {
                if requireHeaders { throw MailStoreError.unparseableMessage("no header fields") }
                // A part with no headers at all: the whole thing is its body.
                bodyStart = bytes.startIndex
                break
            }
            // Any other line in the header block is malformed and skipped, as most readers do.
            index = next
        }
        if let field = current { fields.append((field.name, MIME.headerString(field.value))) }
        if requireHeaders && fields.isEmpty { throw MailStoreError.unparseableMessage("no header fields") }
        headers = HeaderFields(fields: fields)
        body = bodyStart <= bytes.endIndex ? bytes[bodyStart...] : []
    }

    var contentType: MIME.ContentType {
        headers.first("content-type").flatMap(MIME.ContentType.init) ?? .textPlain
    }

    var disposition: MIME.Disposition? {
        headers.first("content-disposition").map(MIME.Disposition.init)
    }

    /// The body with its Content-Transfer-Encoding undone.
    var decodedBody: Data {
        switch headers.first("content-transfer-encoding")?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64": return MIME.decodeBase64(body)
        case "quoted-printable": return MIME.decodeQuotedPrintable(body)
        default: return Data(body)
        }
    }
}

struct HeaderFields {
    var fields: [(name: String, value: String)]

    func first(_ name: String) -> String? { fields.first { $0.name == name }?.value }
    func all(_ name: String) -> [String] { fields.filter { $0.name == name }.map(\.value) }
}

/// Walks a MIME tree and collects the plain text, whether HTML is present, and the attachments.
private struct Walker {
    var text: [String] = []
    var hasHTML = false
    var attachments: [ParsedAttachment] = []
    var leafCount = 0

    mutating func walk(_ entity: Entity, depth: Int) {
        let type = entity.contentType
        if type.type == "multipart" {
            guard depth < BasicMessageParser.maximumDepth, let boundary = type.parameters["boundary"], !boundary.isEmpty else { return }
            for part in MIME.splitMultipart(entity.body, boundary: boundary) {
                guard let child = try? Entity(part, requireHeaders: false) else { continue }
                walk(child, depth: depth + 1)
            }
            return
        }
        leafCount += 1
        guard leafCount <= BasicMessageParser.maximumParts else { return }

        let disposition = entity.disposition
        let fileName = disposition?.parameters["filename"] ?? type.parameters["name"]
        let isAttachment = disposition?.type == "attachment"
        if type.type == "text", type.subtype == "plain", !isAttachment {
            text.append(MIME.normalizeLineEndings(MIME.decodeText(entity.decodedBody, charset: type.parameters["charset"])))
        } else if type.type == "text", type.subtype == "html", !isAttachment {
            hasHTML = true
        } else {
            attachments.append(ParsedAttachment(
                fileName: fileName.map(MIME.decodeEncodedWords),
                mediaType: "\(type.type)/\(type.subtype)",
                isInline: disposition?.type == "inline",
                data: entity.decodedBody
            ))
        }
    }
}

// MARK: - Field syntax

enum MIME {
    struct ContentType {
        var type: String
        var subtype: String
        var parameters: [String: String]

        static let textPlain = ContentType(type: "text", subtype: "plain", parameters: [:])

        init(type: String, subtype: String, parameters: [String: String]) {
            self.type = type
            self.subtype = subtype
            self.parameters = parameters
        }

        init?(_ raw: String) {
            let (value, parameters) = MIME.valueAndParameters(raw)
            let pieces = value.lowercased().split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty else { return nil }
            self.init(type: pieces[0], subtype: pieces[1], parameters: parameters)
        }
    }

    struct Disposition {
        var type: String
        var parameters: [String: String]

        init(_ raw: String) {
            let (value, parameters) = MIME.valueAndParameters(raw)
            type = value.trimmingCharacters(in: .whitespaces).lowercased()
            self.parameters = parameters
        }
    }

    /// The value before the first `;` and the parameters after it, names lowercased, quoted
    /// strings unquoted, RFC 2231 continuations and charsets resolved.
    static func valueAndParameters(_ raw: String) -> (String, [String: String]) {
        let segments = splitOutsideQuotes(raw, separator: ";")
        guard let first = segments.first else { return ("", [:]) }
        var plain: [String: String] = [:]
        var extended: [String: [(index: Int, encoded: Bool, value: String)]] = [:]
        for segment in segments.dropFirst() {
            guard let eq = segment.firstIndex(of: "=") else { continue }
            var name = segment[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = unquote(segment[segment.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            guard !name.isEmpty else { continue }
            if name.contains("*") {
                let encoded = name.hasSuffix("*")
                if encoded { name.removeLast() }
                let parts = name.split(separator: "*", maxSplits: 1)
                let base = String(parts[0])
                let index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                extended[base, default: []].append((index, encoded, value))
            } else if plain[name] == nil {
                plain[name] = value
            }
        }
        for (name, pieces) in extended {
            let sorted = pieces.sorted { $0.index < $1.index }
            var charset: String?
            var bytes: [UInt8] = []
            for (offset, piece) in sorted.enumerated() {
                var value = piece.value
                if piece.encoded && offset == 0 {
                    // charset'language'value
                    let fields = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    if fields.count == 3 {
                        charset = String(fields[0])
                        value = String(fields[2])
                    }
                }
                bytes += piece.encoded ? percentDecode(value) : Array(value.utf8)
            }
            plain[name] = decodeText(Data(bytes), charset: charset)
        }
        return (first, plain)
    }

    static func splitOutsideQuotes(_ raw: String, separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuote = false
        var escaped = false
        for character in raw {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" && inQuote { current.append(character); escaped = true; continue }
            if character == "\"" { inQuote.toggle() }
            if character == separator && !inQuote {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current)
        return result
    }

    static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        var result = ""
        var escaped = false
        for character in value.dropFirst().dropLast() {
            if escaped { result.append(character); escaped = false } else if character == "\\" { escaped = true } else { result.append(character) }
        }
        return result
    }

    static func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The ids in a Message-ID, In-Reply-To or References field, without angle brackets.
    static func messageIDs(_ raw: String) -> [String] {
        var ids: [String] = []
        var current: String?
        for character in raw {
            switch character {
            case "<": current = ""
            case ">":
                if let id = current, !id.isEmpty, !id.contains(where: \.isWhitespace) { ids.append(id) }
                current = nil
            default: current?.append(character)
            }
        }
        return ids
    }

    // MARK: Addresses

    /// An address list: `a@example.com, "Doe, J." <j@example.org>, Team: x@example.net;`.
    static func addresses(_ raw: String) -> [MailAddress] {
        var mailboxes: [String] = []
        var current = ""
        var inQuote = false, escaped = false, angle = 0, paren = 0
        for character in raw {
            if escaped { current.append(character); escaped = false; continue }
            switch character {
            case "\\" where inQuote || paren > 0: escaped = true; current.append(character)
            case "\"" where paren == 0: inQuote.toggle(); current.append(character)
            case "(" where !inQuote: paren += 1; current.append(character)
            case ")" where !inQuote && paren > 0: paren -= 1; current.append(character)
            case "<" where !inQuote && paren == 0: angle += 1; current.append(character)
            case ">" where !inQuote && paren == 0 && angle > 0: angle -= 1; current.append(character)
            case "," where !inQuote && paren == 0 && angle == 0,
                 ";" where !inQuote && paren == 0 && angle == 0:
                mailboxes.append(current); current = ""
            case ":" where !inQuote && paren == 0 && angle == 0:
                // A group's display name ends here; its members follow.
                current = ""
            default: current.append(character)
            }
        }
        mailboxes.append(current)
        return mailboxes.compactMap(mailbox)
    }

    private static func mailbox(_ raw: String) -> MailAddress? {
        var comment = ""
        var text = ""
        var depth = 0, inQuote = false
        for character in raw {
            if character == "\"" && depth == 0 { inQuote.toggle() }
            if character == "(" && !inQuote { depth += 1; if depth == 1 { continue } }
            if character == ")" && !inQuote && depth > 0 { depth -= 1; if depth == 0 { continue } }
            if depth > 0 { comment.append(character) } else { text.append(character) }
        }
        if let open = text.lastIndex(of: "<"), let close = text[open...].firstIndex(of: ">") {
            let address = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            let route = address.lastIndex(of: ":").map { String(address[address.index(after: $0)...]) } ?? address
            guard !route.isEmpty else { return nil }
            let rawName = text[..<open].trimmingCharacters(in: .whitespaces)
            let name = decodeEncodedWords(unquote(rawName)).trimmingCharacters(in: .whitespaces)
            return MailAddress(name: name.isEmpty ? nil : name, address: route)
        }
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        let name = decodeEncodedWords(comment).trimmingCharacters(in: .whitespaces)
        return MailAddress(name: name.isEmpty ? nil : name, address: address)
    }

    // MARK: Dates

    /// An RFC 5322 date (with the obsolete forms of 4.3: two-digit years, named zones).
    static func date(_ raw: String) -> Date? {
        var text = ""
        var depth = 0
        for character in raw {
            if character == "(" { depth += 1; continue }
            if character == ")" { depth = max(0, depth - 1); continue }
            if depth == 0 { text.append(character) }
        }
        if let comma = text.firstIndex(of: ",") { text = String(text[text.index(after: comma)...]) }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 4,
              let day = Int(tokens[0]), (1...31).contains(day),
              let month = months[tokens[1].lowercased().prefix(3).description],
              var year = Int(tokens[2]) else { return nil }
        if tokens[2].count <= 2 { year += year < 50 ? 2000 : 1900 } else if tokens[2].count == 3 { year += 1900 }
        let time = tokens[3].split(separator: ":").compactMap { Int($0) }
        guard time.count >= 2, (0...23).contains(time[0]), (0...59).contains(time[1]) else { return nil }
        let second = time.count > 2 ? time[2] : 0
        let offset = tokens.count > 4 ? zoneOffset(tokens[4]) : 0

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: year, month: month, day: day, hour: time[0], minute: time[1], second: min(second, 60))
        guard let utc = calendar.date(from: components) else { return nil }
        return utc.addingTimeInterval(TimeInterval(-offset))
    }

    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                 "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    /// Seconds east of UTC. Unknown zones count as UTC, as RFC 5322 4.3 asks.
    private static func zoneOffset(_ zone: String) -> Int {
        if let sign = zone.first, sign == "+" || sign == "-", zone.count == 5, let value = Int(zone.dropFirst()) {
            let seconds = (value / 100) * 3600 + (value % 100) * 60
            return sign == "-" ? -seconds : seconds
        }
        let named = ["ut": 0, "gmt": 0, "z": 0, "edt": -4, "est": -5, "cdt": -5, "cst": -6, "mdt": -6, "mst": -7, "pdt": -7, "pst": -8]
        return (named[zone.lowercased()] ?? 0) * 3600
    }

    // MARK: Encodings

    /// A header's raw bytes as a string: UTF-8 when valid (RFC 6532), Latin-1 otherwise.
    static func headerString(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    static func decodeText(_ data: Data, charset: String?) -> String {
        if let charset, let encoding = encoding(for: charset), let text = String(data: data, encoding: encoding) {
            return text
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    static func encoding(for charset: String) -> String.Encoding? {
        let name = charset.trimmingCharacters(in: .whitespaces).lowercased()
        if name == "us-ascii" || name == "ascii" { return .utf8 }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// RFC 2047 encoded words (`=?utf-8?q?…?=`, `=?iso-8859-1?b?…?=`). Whitespace between two
    /// adjacent encoded words is dropped (6.2); a word that cannot be decoded is kept as written.
    static func decodeEncodedWords(_ raw: String) -> String {
        guard raw.contains("=?") else { return raw }
        var output = ""
        var pendingGap = ""
        var previousWasEncoded = false
        var rest = Substring(raw)
        while let start = rest.range(of: "=?") {
            let before = rest[..<start.lowerBound]
            let afterStart = rest[start.upperBound...]
            guard let decoded = encodedWord(afterStart) else {
                output += pendingGap + before + "=?"
                pendingGap = ""
                previousWasEncoded = false
                rest = afterStart
                continue
            }
            if previousWasEncoded && before.allSatisfy(\.isWhitespace) {
                // Adjacent encoded words: the space between them is not part of the text.
            } else {
                output += pendingGap + before
            }
            pendingGap = ""
            output += decoded.text
            previousWasEncoded = true
            rest = rest[decoded.end...]
        }
        output += pendingGap + rest
        return output
    }

    /// Reads `charset?enc?text?=` at the start of `text`.
    private static func encodedWord(_ text: Substring) -> (text: String, end: Substring.Index)? {
        let fields = text.split(separator: "?", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 4, fields[3].hasPrefix("="), !fields[0].isEmpty,
              !fields[2].contains(where: \.isWhitespace) else { return nil }
        let charset = fields[0].split(separator: "*").first.map(String.init) ?? ""
        let payload = Array(fields[2].utf8)
        let bytes: Data
        switch fields[1].lowercased() {
        case "b": bytes = decodeBase64(payload[...])
        case "q": bytes = Data(decodeQ(payload))
        default: return nil
        }
        guard let encoding = encoding(for: charset), let decoded = String(data: bytes, encoding: encoding) else { return nil }
        return (decoded, text.index(after: fields[3].startIndex))
    }

    private static func decodeQ(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 0x5F { out.append(0x20); i += 1 } else if byte == 0x3D, i + 2 < bytes.count, let value = hexByte(bytes[i + 1], bytes[i + 2]) {
                out.append(value); i += 3
            } else { out.append(byte); i += 1 }
        }
        return out
    }

    static func decodeBase64(_ bytes: ArraySlice<UInt8>) -> Data {
        var clean = bytes.filter { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2B || $0 == 0x2F }
        // Padding is recomputed: stray or missing `=` must not lose the whole part.
        while clean.count % 4 == 1 { clean.removeLast() }
        while clean.count % 4 != 0 { clean.append(0x3D) }
        return Data(base64Encoded: Data(clean)) ?? Data()
    }

    static func decodeQuotedPrintable(_ bytes: ArraySlice<UInt8>) -> Data {
        var out = Data()
        out.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let byte = bytes[i]
            if byte == 0x3D {
                let next = bytes.index(after: i)
                if next < bytes.endIndex, bytes[next] == 0x0A { i = bytes.index(after: next); continue }
                if next < bytes.endIndex, bytes[next] == 0x0D {
                    let after = bytes.index(after: next)
                    i = after < bytes.endIndex && bytes[after] == 0x0A ? bytes.index(after: after) : after
                    continue
                }
                if bytes.distance(from: i, to: bytes.endIndex) >= 3, let value = hexByte(bytes[next], bytes[next + 1]) {
                    out.append(value); i += 3; continue
                }
            }
            out.append(byte)
            i += 1
        }
        return out
    }

    private static func hexByte(_ high: UInt8, _ low: UInt8) -> UInt8? {
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x41...0x46: return c - 0x41 + 10
            case 0x61...0x66: return c - 0x61 + 10
            default: return nil
            }
        }
        guard let h = nibble(high), let l = nibble(low) else { return nil }
        return h << 4 | l
    }

    private static func percentDecode(_ value: String) -> [UInt8] {
        let bytes = Array(value.utf8)
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25, i + 2 < bytes.count, let value = hexByte(bytes[i + 1], bytes[i + 2]) {
                out.append(value); i += 3
            } else { out.append(bytes[i]); i += 1 }
        }
        return out
    }

    // MARK: Multipart

    /// The body parts between `--boundary` lines, each without the line break that belongs to
    /// the delimiter. The preamble and epilogue are dropped (RFC 2046, 5.1.1).
    static func splitMultipart(_ body: ArraySlice<UInt8>, boundary: String) -> [ArraySlice<UInt8>] {
        let delimiter = Array("--\(boundary)".utf8)
        var parts: [ArraySlice<UInt8>] = []
        var partStart: Int?
        var lineStart = body.startIndex
        while lineStart < body.endIndex {
            let lineEnd = body[lineStart...].firstIndex(of: 0x0A) ?? body.endIndex
            let line = body[lineStart..<lineEnd]
            if line.starts(with: delimiter) {
                let tail = line.dropFirst(delimiter.count)
                let isClose = tail.starts(with: [0x2D, 0x2D])
                let rest = isClose ? tail.dropFirst(2) : tail
                if rest.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                    if let start = partStart {
                        // The CRLF before the delimiter belongs to the delimiter.
                        var end = lineStart
                        if end > start, body[end - 1] == 0x0A { end -= 1 }
                        if end > start, body[end - 1] == 0x0D { end -= 1 }
                        parts.append(body[start..<max(start, end)])
                    }
                    if isClose { return parts }
                    partStart = lineEnd < body.endIndex ? lineEnd + 1 : body.endIndex
                }
            }
            lineStart = lineEnd < body.endIndex ? lineEnd + 1 : body.endIndex
        }
        // No closing delimiter: keep what was opened, as most readers do.
        if let start = partStart, start < body.endIndex { parts.append(body[start...]) }
        return parts
    }
}
