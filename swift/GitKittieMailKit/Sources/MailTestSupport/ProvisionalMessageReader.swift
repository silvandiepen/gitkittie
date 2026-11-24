import Foundation
import MailCore

// PROVISIONAL. A deliberately small RFC 5322 / MIME reader so the fixture corpus (GKM-003)
// and the classifier baseline (GKM-007) can run before the MIME library is chosen (GKM-002).
// It lives in MailTestSupport, which never ships. It reads headers (with RFC 2047 encoded
// words and RFC 2231 parameters), walks multipart bodies with a depth limit, decodes base64
// and quoted-printable, and reports what it had to repair or refuse as `ParseWarning`s.
// It does not do: S/MIME, message/rfc822 recursion, RFC 2231 continuations, uuencode, TNEF,
// or anything streaming. Replace it with the chosen library and keep the expectations: the
// warnings and outcomes in expectations.json are the contract the real parser must meet.

/// What the reader made of a fixture.
public enum ParseOutcome: String, Codable, CaseIterable, Sendable {
    /// Well-formed; nothing repaired.
    case ok
    /// Malformed, but all content was recovered with warnings.
    case recovered
    /// A safety limit applied: something was refused, truncated or renamed.
    case limited
}

/// One thing the reader had to repair or refuse. Stable identifiers: tests and expectations use them.
public enum ParseWarning: String, Codable, CaseIterable, Sendable {
    case missingMessageID = "missing-message-id"
    case duplicateMessageIDHeader = "duplicate-message-id-header"
    case bareLFLineEndings = "bare-lf-line-endings"
    case raw8BitHeader = "raw-8bit-header"
    case malformedEncodedWord = "malformed-encoded-word"
    case unknownCharset = "unknown-charset"
    case missingBoundaryParameter = "missing-boundary-parameter"
    case boundaryNotFound = "boundary-not-found"
    case missingClosingBoundary = "missing-closing-boundary"
    case nestingLimitExceeded = "nesting-limit-exceeded"
    case declaredSizeExceedsLimit = "declared-size-exceeds-limit"
    case unsafeAttachmentFilename = "unsafe-attachment-filename"

    /// Warnings where the reader refused or rewrote content rather than repairing it.
    public var isLimit: Bool {
        switch self {
        case .nestingLimitExceeded, .declaredSizeExceedsLimit, .unsafeAttachmentFilename: true
        default: false
        }
    }
}

public struct ProvisionalHeader: Sendable, Equatable {
    public var name: String
    /// Unfolded, RFC 2047 decoded.
    public var value: String
}

public struct ProvisionalAttachment: Sendable, Equatable {
    /// The filename as the sender wrote it (decoded). Never use it as a path.
    public var rawFilename: String?
    /// A single, safe path component derived from `rawFilename`.
    public var safeFilename: String
    public var mimeType: String
    /// The size the sender declared (Content-Disposition `size`), never trusted.
    public var declaredSize: Int64?
    public var decodedByteCount: Int
}

public struct ProvisionalMessage: Sendable {
    public var headers: [ProvisionalHeader]
    public var textBody: String?
    public var htmlBody: String?
    public var attachments: [ProvisionalAttachment]
    public var warnings: Set<ParseWarning>

    public var outcome: ParseOutcome {
        if warnings.contains(where: \.isLimit) { return .limited }
        return warnings.isEmpty ? .ok : .recovered
    }

    public func values(_ name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    public func value(_ name: String) -> String? { values(name).first }

    public var subject: String { value("Subject") ?? "" }
    public var messageID: String? { value("Message-ID")?.trimmingCharacters(in: .whitespaces) }
    public var from: [MailAddress] { values("From").flatMap(ProvisionalMessageReader.parseAddressList) }
    public var replyTo: [MailAddress] { values("Reply-To").flatMap(ProvisionalMessageReader.parseAddressList) }
}

public enum ProvisionalMessageReader {
    /// Deepest multipart nesting the reader descends into. Real mail rarely passes 5.
    public static let maxDepth = 16
    /// Declared attachment sizes above this are reported (and would be refused for download).
    public static let maxDeclaredAttachmentSize: Int64 = 100 * 1024 * 1024

    public static func read(_ data: Data) -> ProvisionalMessage {
        // ISO-8859-1 maps every byte to one scalar, so MIME structure can be walked as text
        // and leaf bytes recovered exactly with `latin1Bytes`.
        let raw = String(decoding: data.map { UInt16($0) }, as: UTF16.self)
        var state = State()
        if hasBareLF(raw) { state.warnings.insert(.bareLFLineEndings) }
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }

        let entity = splitEntity(lines[...])
        let headers = decodeHeaders(entity.headers, state: &state)
        let ids = headers.filter { $0.name.lowercased() == "message-id" }
        if ids.isEmpty { state.warnings.insert(.missingMessageID) }
        if ids.count > 1 { state.warnings.insert(.duplicateMessageIDHeader) }

        walk(rawHeaders: entity.headers, body: entity.body, depth: 0, state: &state)
        return ProvisionalMessage(headers: headers, textBody: state.text, htmlBody: state.html,
                                  attachments: state.attachments, warnings: state.warnings)
    }

    // MARK: - Structure

    private struct State {
        var warnings: Set<ParseWarning> = []
        var text: String?
        var html: String?
        var attachments: [ProvisionalAttachment] = []
    }

    private static func hasBareLF(_ s: String) -> Bool {
        var previous: Unicode.Scalar = " "
        for scalar in s.unicodeScalars {
            if scalar == "\n" && previous != "\r" { return true }
            previous = scalar
        }
        return false
    }

    private static func splitEntity(_ lines: ArraySlice<String>) -> (headers: [(String, String)], body: ArraySlice<String>) {
        var headers: [(String, String)] = []
        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            if line.isEmpty { index += 1; break }
            if let first = line.unicodeScalars.first, first == " " || first == "\t", !headers.isEmpty {
                headers[headers.count - 1].1 += line
            } else if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers.append((name, value))
            }
            index += 1
        }
        return (headers, lines[index...])
    }

    private static func decodeHeaders(_ raw: [(String, String)], state: inout State) -> [ProvisionalHeader] {
        raw.map { name, value in
            var text = value
            if value.unicodeScalars.contains(where: { $0.value > 127 }) {
                state.warnings.insert(.raw8BitHeader)
                text = String(data: latin1Bytes(value), encoding: .utf8) ?? value
            }
            return ProvisionalHeader(name: name, value: decodeEncodedWords(text, warnings: &state.warnings))
        }
    }

    private static func walk(rawHeaders: [(String, String)], body: ArraySlice<String>, depth: Int, state: inout State) {
        func header(_ name: String) -> String? {
            rawHeaders.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
        }
        let contentType = parseParameters(header("Content-Type") ?? "text/plain; charset=us-ascii")
        let mimeType = contentType.value.isEmpty ? "text/plain" : contentType.value
        let transfer = (header("Content-Transfer-Encoding") ?? "7bit").lowercased().trimmingCharacters(in: .whitespaces)

        if mimeType.hasPrefix("multipart/") {
            guard depth < maxDepth else { state.warnings.insert(.nestingLimitExceeded); return }
            guard let boundary = contentType.parameters["boundary"], !boundary.isEmpty else {
                state.warnings.insert(.missingBoundaryParameter)
                addText(body, transfer: transfer, charset: "utf-8", html: false, state: &state)
                return
            }
            let delimiter = "--" + boundary
            var parts: [ArraySlice<String>] = []
            var start: Int?
            var closed = false
            for index in body.indices {
                let line = body[index].trimmingCharacters(in: .whitespaces)
                if line == delimiter || line == delimiter + "--" {
                    if let start { parts.append(body[start..<index]) }
                    if line != delimiter { closed = true; start = nil; break }
                    start = index + 1
                }
            }
            if parts.isEmpty && start == nil && !closed {
                state.warnings.insert(.boundaryNotFound)
                addText(body, transfer: transfer, charset: "utf-8", html: false, state: &state)
                return
            }
            if let start, !closed {
                state.warnings.insert(.missingClosingBoundary)
                parts.append(body[start...])
            }
            for part in parts {
                let entity = splitEntity(part)
                walk(rawHeaders: entity.headers, body: entity.body, depth: depth + 1, state: &state)
            }
            return
        }

        let disposition = parseParameters(header("Content-Disposition") ?? "")
        var filename = disposition.parameters["filename"] ?? contentType.parameters["name"]
        if let name = filename { filename = decodeEncodedWords(name, warnings: &state.warnings) }
        let isAttachment = disposition.value == "attachment" || filename != nil
        if !isAttachment && (mimeType == "text/plain" || mimeType == "text/html") {
            addText(body, transfer: transfer, charset: contentType.parameters["charset"] ?? "us-ascii",
                    html: mimeType == "text/html", state: &state)
            return
        }

        let bytes = decodeTransfer(body, transfer: transfer)
        var declared: Int64?
        if let size = disposition.parameters["size"], let value = Int64(size) {
            declared = value
            if value > maxDeclaredAttachmentSize { state.warnings.insert(.declaredSizeExceedsLimit) }
        }
        let safe = safeFilename(filename)
        if !safe.wasSafe { state.warnings.insert(.unsafeAttachmentFilename) }
        state.attachments.append(ProvisionalAttachment(rawFilename: filename, safeFilename: safe.name, mimeType: mimeType,
                                                       declaredSize: declared, decodedByteCount: bytes.count))
    }

    private static func addText(_ body: ArraySlice<String>, transfer: String, charset: String, html: Bool, state: inout State) {
        let bytes = decodeTransfer(body, transfer: transfer)
        let text: String
        if let decoded = decode(bytes, charset: charset) {
            text = decoded
        } else {
            state.warnings.insert(.unknownCharset)
            text = String(data: bytes, encoding: .utf8) ?? String(decoding: bytes.map { UInt16($0) }, as: UTF16.self)
        }
        if html {
            if state.html == nil { state.html = text }
        } else {
            state.text = state.text.map { $0 + "\n" + text } ?? text
        }
    }

    // MARK: - Decoding

    static func latin1Bytes(_ s: String) -> Data {
        Data(s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
    }

    private static func decodeTransfer(_ body: ArraySlice<String>, transfer: String) -> Data {
        let joined = body.joined(separator: "\n")
        switch transfer {
        case "base64":
            return Data(base64Encoded: joined, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            return decodeQuotedPrintable(joined, underscoreIsSpace: false)
        default:
            return latin1Bytes(joined)
        }
    }

    private static func decodeQuotedPrintable(_ s: String, underscoreIsSpace: Bool) -> Data {
        var out = Data()
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "=" {
                if i + 1 < scalars.count && scalars[i + 1] == "\n" { i += 2; continue }
                if i + 2 < scalars.count, let byte = UInt8(String(scalars[i + 1]) + String(scalars[i + 2]), radix: 16) {
                    out.append(byte); i += 3; continue
                }
            }
            if underscoreIsSpace && c == "_" { out.append(0x20) } else { out.append(UInt8(truncatingIfNeeded: c.value)) }
            i += 1
        }
        return out
    }

    /// Decodes `bytes` in an IANA charset; nil when the charset is unknown or the bytes don't fit.
    static func decode(_ bytes: Data, charset: String) -> String? {
        let name = charset.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
        if name == "us-ascii" || name == "ascii" || name == "utf-8" || name == "utf8" {
            return String(data: bytes, encoding: .utf8)
        }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        return String(data: bytes, encoding: encoding)
    }

    private static let encodedWord = try! NSRegularExpression(pattern: #"=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?="#)
    private static let encodedWordStart = try! NSRegularExpression(pattern: #"=\?[^?\s]+\?[BbQq]\?"#)

    /// RFC 2047: decodes encoded words; whitespace between adjacent encoded words is dropped.
    static func decodeEncodedWords(_ s: String, warnings: inout Set<ParseWarning>) -> String {
        let ns = s as NSString
        var out = ""
        var cursor = 0
        var lastWasWord = false
        for match in encodedWord.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if !(lastWasWord && gap.trimmingCharacters(in: .whitespaces).isEmpty) { out += gap }
            let charset = ns.substring(with: match.range(at: 1)).split(separator: "*").first.map(String.init) ?? ""
            let encoding = ns.substring(with: match.range(at: 2)).uppercased()
            let payload = ns.substring(with: match.range(at: 3))
            let bytes: Data? = encoding == "B"
                ? Data(base64Encoded: padBase64(payload))
                : decodeQuotedPrintable(payload, underscoreIsSpace: true)
            if let bytes, let text = decode(bytes, charset: charset) {
                out += text
            } else {
                let known = ["us-ascii", "ascii", "utf-8", "utf8"].contains(charset.lowercased())
                    || CFStringConvertIANACharSetNameToEncoding(charset as CFString) != kCFStringEncodingInvalidId
                warnings.insert(known ? .malformedEncodedWord : .unknownCharset)
                out += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
            lastWasWord = true
        }
        let tail = ns.substring(from: cursor)
        if encodedWordStart.firstMatch(in: tail, range: NSRange(location: 0, length: (tail as NSString).length)) != nil {
            warnings.insert(.malformedEncodedWord)
        }
        return out + tail
    }

    private static func padBase64(_ s: String) -> String {
        let remainder = s.count % 4
        return remainder == 0 ? s : s + String(repeating: "=", count: 4 - remainder)
    }

    // MARK: - Parameters, filenames, addresses

    /// `type/subtype; a=b; c="d"` with quoted-pair unescaping and RFC 2231 `name*=charset''value`.
    static func parseParameters(_ raw: String) -> (value: String, parameters: [String: String]) {
        var pieces: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for c in raw {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\" && quoted { current.append(c); escaped = true; continue }
            if c == "\"" { quoted.toggle() }
            if c == ";" && !quoted { pieces.append(current); current = ""; continue }
            current.append(c)
        }
        pieces.append(current)
        let value = pieces.removeFirst().trimmingCharacters(in: .whitespaces).lowercased()
        var parameters: [String: String] = [:]
        for piece in pieces {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            var name = piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var v = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                v = String(v.dropFirst().dropLast())
                var unescaped = ""
                var escape = false
                for c in v {
                    if escape { unescaped.append(c); escape = false } else if c == "\\" { escape = true } else { unescaped.append(c) }
                }
                v = unescaped
            }
            if name.hasSuffix("*") {
                name.removeLast()
                let parts = v.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count == 3 {
                    let bytes = latin1Bytes(String(parts[2]).removingPercentEncodingBytes())
                    v = decode(bytes, charset: String(parts[0])) ?? String(parts[2])
                }
            }
            parameters[name] = v
        }
        return (value, parameters)
    }

    /// A single safe path component. `wasSafe` is false when the sender's name tried to be a path.
    static func safeFilename(_ raw: String?) -> (name: String, wasSafe: Bool) {
        guard let raw, !raw.isEmpty else { return ("attachment", true) }
        let components = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        let hasControl = raw.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        let wasSafe = components.count == 1 && !hasControl && raw != "." && raw != ".."
            && !raw.contains("/") && !raw.contains("\\")
        var name = String(components.last ?? "")
        name = String(name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init))
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "attachment" }
        return (name, wasSafe)
    }

    /// `Name <a@b>, "Quoted, Name" <c@d>, e@f`. Groups are flattened; empty groups dropped.
    public static func parseAddressList(_ raw: String) -> [MailAddress] {
        var items: [String] = []
        var current = ""
        var quoted = false
        var angle = false
        for c in raw {
            if c == "\"" { quoted.toggle() }
            if !quoted { if c == "<" { angle = true } else if c == ">" { angle = false } }
            if c == "," && !quoted && !angle { items.append(current); current = ""; continue }
            current.append(c)
        }
        items.append(current)
        return items.compactMap { item in
            let trimmed = item.trimmingCharacters(in: .whitespaces)
            var quotedState = false
            var open: String.Index?
            for index in trimmed.indices {
                let c = trimmed[index]
                if c == "\"" { quotedState.toggle() } else if c == "<" && !quotedState { open = index }
            }
            if let open, let close = trimmed[open...].firstIndex(of: ">") {
                let address = String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                var name = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 { name = String(name.dropFirst().dropLast()) }
                guard address.contains("@") else { return nil }
                return MailAddress(name: name.isEmpty ? nil : name, address: address)
            }
            guard trimmed.contains("@"), !trimmed.contains(" ") else { return nil }
            return MailAddress(address: trimmed)
        }
    }
}

private extension String {
    /// Percent-decoding into raw bytes (as Latin-1 scalars), leaving invalid escapes alone.
    func removingPercentEncodingBytes() -> String {
        var out = ""
        let scalars = Array(unicodeScalars)
        var i = 0
        while i < scalars.count {
            if scalars[i] == "%", i + 2 < scalars.count, let byte = UInt8(String(scalars[i + 1]) + String(scalars[i + 2]), radix: 16) {
                out.unicodeScalars.append(Unicode.Scalar(byte)); i += 3
            } else {
                out.unicodeScalars.append(scalars[i]); i += 1
            }
        }
        return out
    }
}
