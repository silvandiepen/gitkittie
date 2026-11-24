import Foundation
import MailCore

public struct MIMEHeader: Sendable, Hashable {
    public var name: String
    /// Unfolded, not decoded: RFC 2047 words are still encoded.
    public var rawValue: String
}

public struct MIMEHeaders: Sendable, Hashable, Sequence {
    public private(set) var fields: [MIMEHeader]

    public init(_ fields: [MIMEHeader] = []) { self.fields = fields }

    public func makeIterator() -> IndexingIterator<[MIMEHeader]> { fields.makeIterator() }

    /// The first field with this name, raw.
    public subscript(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.rawValue
    }

    public func all(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.rawValue)
    }

    /// The first field with this name, RFC 2047 decoded.
    public func decoded(_ name: String) -> String? {
        self[name].map { EncodedWords.decode($0) }
    }
}

/// One MIME entity: a leaf with a body, or a multipart with children.
public struct MIMEPart: Sendable, Hashable {
    public var headers: MIMEHeaders
    public var contentType: ParameterizedValue
    public var children: [MIMEPart]
    /// The body after Content-Transfer-Encoding decoding (leaves only; empty for multiparts).
    public var body: Data
    /// A message/rfc822 attachment, parsed.
    public var embeddedMessage: MIMEMessageBox?

    public var mimeType: String { contentType.value }
    public var isMultipart: Bool { mimeType.hasPrefix("multipart/") }
    public var charset: String? { contentType.parameters["charset"] }

    public var disposition: ParameterizedValue? {
        headers["Content-Disposition"].map(ParameterizedValue.parse)
    }

    /// The name the sender gave the file, made safe to use as a file name: no path separators,
    /// no control characters, no leading dots, at most 255 bytes.
    public var filename: String? {
        let raw = disposition?.parameters["filename"] ?? contentType.parameters["name"]
        return raw.map(MIMEPart.safeFilename)
    }

    public var contentID: String? {
        headers["Content-ID"].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " <>")) }
    }

    public var isAttachment: Bool {
        if isMultipart { return false }
        if disposition?.value == "attachment" { return true }
        if disposition?.value == "inline", filename != nil, !mimeType.hasPrefix("text/") { return true }
        if filename != nil { return true }
        return !(mimeType.hasPrefix("text/") || mimeType.isEmpty) && mimeType != "message/delivery-status"
    }

    /// The body as text, in its declared charset.
    public var text: String? {
        guard mimeType.hasPrefix("text/") else { return nil }
        return Charsets.decode(body, charset: charset)
    }

    /// Every leaf part, depth first.
    public var leaves: [MIMEPart] {
        isMultipart ? children.flatMap(\.leaves) : [self]
    }

    public static func safeFilename(_ name: String) -> String {
        var cleaned = String(name.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == "\\" || scalar == ":" { return "_" }
            if scalar.properties.generalCategory == .control || scalar.value == 0x7F { return "_" }
            if [0x202E, 0x202D, 0x202A, 0x202B, 0x2066, 0x2067, 0x2068, 0x2069].contains(scalar.value) { return "_" } // bidi overrides
            return Character(scalar)
        })
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = "attachment" }
        while cleaned.utf8.count > 255 { cleaned.removeFirst() }
        return cleaned
    }
}

/// Boxes a parsed message/rfc822 part (structs cannot contain themselves directly).
public final class MIMEMessageBox: Sendable, Hashable {
    public let message: MIMEMessage
    init(_ message: MIMEMessage) { self.message = message }
    public static func == (lhs: MIMEMessageBox, rhs: MIMEMessageBox) -> Bool { lhs.message == rhs.message }
    public func hash(into hasher: inout Hasher) { hasher.combine(message) }
}

/// A parsed RFC 5322 message.
public struct MIMEMessage: Sendable, Hashable {
    public var root: MIMEPart
    /// What was wrong with the input and how it was handled. Parsing never throws: hostile or
    /// broken mail still yields as much as can be read safely.
    public var problems: [String]

    public var headers: MIMEHeaders { root.headers }
    public var subject: String? { headers.decoded("Subject") }
    public var from: [MailAddress] { headers["From"].map(AddressParser.parseList) ?? [] }
    public var to: [MailAddress] { headers.all("To").flatMap(AddressParser.parseList) }
    public var cc: [MailAddress] { headers.all("Cc").flatMap(AddressParser.parseList) }
    public var replyTo: [MailAddress] { headers["Reply-To"].map(AddressParser.parseList) ?? [] }
    public var date: Date? { headers["Date"].flatMap(MailDates.parse) }
    /// Without angle brackets. Missing or duplicate ids happen; never treat this as unique.
    public var messageID: String? { Self.messageIDs(headers["Message-ID"] ?? "").first }
    public var inReplyTo: [String] { Self.messageIDs(headers["In-Reply-To"] ?? "") }
    public var references: [String] { Self.messageIDs(headers["References"] ?? "") }

    public var textBody: String? { root.leaves.first { $0.mimeType == "text/plain" && !$0.isAttachment }?.text }
    public var htmlBody: String? { root.leaves.first { $0.mimeType == "text/html" && !$0.isAttachment }?.text }
    public var attachments: [MIMEPart] { root.leaves.filter(\.isAttachment) }

    public static func messageIDs(_ raw: String) -> [String] {
        var ids: [String] = []
        var rest = Substring(raw)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            let id = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if !id.isEmpty { ids.append(id) }
            rest = rest[rest.index(after: close)...]
        }
        if ids.isEmpty {
            let bare = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !bare.isEmpty, !bare.contains(" ") { ids.append(bare) }
        }
        return ids
    }
}

public enum MIMEParser {
    public struct Limits: Sendable {
        public var maximumDepth = 32
        public var maximumParts = 2_000
        public var maximumHeaderBytes = 512 * 1024
        public var maximumHeaderFields = 2_000
        public init() {}
    }

    public static func parse(_ data: Data, limits: Limits = Limits()) -> MIMEMessage {
        var state = State(limits: limits)
        let root = parseEntity(ArraySlice(data), depth: 0, defaultType: "text/plain", state: &state)
        return MIMEMessage(root: root, problems: state.problems)
    }

    struct State {
        var limits: Limits
        var parts = 0
        var problems: [String] = []
    }

    static func parseEntity(_ bytes: ArraySlice<UInt8>, depth: Int, defaultType: String, state: inout State) -> MIMEPart {
        state.parts += 1
        let (headers, body) = splitHeaders(bytes, state: &state)
        let contentType = headers["Content-Type"].map(ParameterizedValue.parse)
            .flatMap { $0.value.contains("/") ? $0 : nil }
            ?? ParameterizedValue(value: defaultType, parameters: defaultType == "text/plain" ? ["charset": "us-ascii"] : [:])
        var part = MIMEPart(headers: headers, contentType: contentType, children: [], body: Data(), embeddedMessage: nil)

        if contentType.value.hasPrefix("multipart/") {
            guard let boundary = contentType.parameters["boundary"], !boundary.isEmpty, boundary.utf8.count <= 200 else {
                state.problems.append("multipart without a usable boundary; kept as one opaque part")
                part.contentType = ParameterizedValue(value: "application/octet-stream", parameters: [:])
                part.body = Data(body)
                return part
            }
            guard depth < state.limits.maximumDepth else {
                state.problems.append("nesting deeper than \(state.limits.maximumDepth); the rest is kept opaque")
                part.body = Data(body)
                return part
            }
            let childDefault = contentType.value == "multipart/digest" ? "message/rfc822" : "text/plain"
            for section in splitMultipart(body, boundary: boundary, state: &state) {
                guard state.parts < state.limits.maximumParts else {
                    state.problems.append("more than \(state.limits.maximumParts) parts; the rest is ignored")
                    break
                }
                part.children.append(parseEntity(section, depth: depth + 1, defaultType: childDefault, state: &state))
            }
            return part
        }

        part.body = decodeBody(body, encoding: headers["Content-Transfer-Encoding"])
        if contentType.value == "message/rfc822", depth < state.limits.maximumDepth {
            var inner = State(limits: state.limits)
            inner.parts = state.parts
            let root = parseEntity(ArraySlice(part.body), depth: depth + 1, defaultType: "text/plain", state: &inner)
            state.parts = inner.parts
            part.embeddedMessage = MIMEMessageBox(MIMEMessage(root: root, problems: inner.problems))
        }
        return part
    }

    static func decodeBody(_ body: ArraySlice<UInt8>, encoding: String?) -> Data {
        switch encoding?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64": TransferEncoding.decodeBase64(Data(body))
        case "quoted-printable": TransferEncoding.decodeQuotedPrintable(Data(body))
        default: Data(body)
        }
    }

    /// Splits header section and body at the first empty line (CRLF or bare LF).
    static func splitHeaders(_ bytes: ArraySlice<UInt8>, state: inout State) -> (MIMEHeaders, ArraySlice<UInt8>) {
        var lines: [ArraySlice<UInt8>] = []
        var index = bytes.startIndex
        var bodyStart = bytes.endIndex
        var lineStart = index
        while index < bytes.endIndex {
            if bytes[index] == 0x0A {
                var line = bytes[lineStart..<index]
                if line.last == 0x0D { line = line.dropLast() }
                if line.isEmpty {
                    bodyStart = index + 1
                    break
                }
                lines.append(line)
                lineStart = index + 1
                if index - bytes.startIndex > state.limits.maximumHeaderBytes {
                    state.problems.append("header section over \(state.limits.maximumHeaderBytes) bytes; truncated")
                    bodyStart = index + 1
                    break
                }
            }
            index += 1
        }
        if index >= bytes.endIndex && lineStart < bytes.endIndex {
            lines.append(bytes[lineStart..<bytes.endIndex])
        }
        // A first line that is not a header means there is no header section at all.
        if let first = lines.first, !looksLikeHeader(first) {
            return (MIMEHeaders(), bytes)
        }
        var fields: [MIMEHeader] = []
        for line in lines {
            let text = decodeHeaderBytes(line)
            if let first = line.first, first == 0x20 || first == 0x09, !fields.isEmpty {
                let continuation = text.trimmingCharacters(in: .whitespaces)
                let current = fields[fields.count - 1].rawValue
                fields[fields.count - 1].rawValue = current.isEmpty ? continuation : current + " " + continuation
                continue
            }
            guard let colon = text.firstIndex(of: ":") else {
                state.problems.append("header line without a colon ignored")
                continue
            }
            guard fields.count < state.limits.maximumHeaderFields else {
                state.problems.append("more than \(state.limits.maximumHeaderFields) header fields; the rest is ignored")
                break
            }
            fields.append(MIMEHeader(
                name: text[text.startIndex..<colon].trimmingCharacters(in: .whitespaces),
                rawValue: text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            ))
        }
        return (MIMEHeaders(fields), bytes[min(bodyStart, bytes.endIndex)...])
    }

    private static func looksLikeHeader(_ line: ArraySlice<UInt8>) -> Bool {
        guard let colon = line.firstIndex(of: UInt8(ascii: ":")), colon > line.startIndex else { return false }
        return line[line.startIndex..<colon].allSatisfy { $0 > 0x20 && $0 < 0x7F }
    }

    /// Header bytes are ASCII by the RFC, UTF-8 in practice (RFC 6532), and sometimes Latin-1.
    private static func decodeHeaderBytes(_ bytes: ArraySlice<UInt8>) -> String {
        let array = Array(bytes)
        return String(bytes: array, encoding: .utf8) ?? String(bytes: array, encoding: .isoLatin1) ?? ""
    }

    /// The body parts between `--boundary` lines (RFC 2046 5.1.1). The line break before a
    /// delimiter belongs to the delimiter. A missing final delimiter is tolerated.
    static func splitMultipart(_ body: ArraySlice<UInt8>, boundary: String, state: inout State) -> [ArraySlice<UInt8>] {
        let delimiter = Array("--\(boundary)".utf8)
        var sections: [ArraySlice<UInt8>] = []
        var currentStart: Int?
        var lineStart = body.startIndex
        var sawClose = false
        var index = body.startIndex
        while lineStart < body.endIndex {
            index = body[lineStart...].firstIndex(of: 0x0A) ?? body.endIndex
            let line = body[lineStart..<index]
            if line.starts(with: delimiter) {
                let rest = line.dropFirst(delimiter.count)
                let isClose = rest.starts(with: [UInt8(ascii: "-"), UInt8(ascii: "-")])
                let restTrimmed = isClose ? rest.dropFirst(2) : rest
                if restTrimmed.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                    if let start = currentStart {
                        var end = lineStart
                        // Drop the CRLF (or LF) that precedes the delimiter.
                        if end > start, body[end - 1] == 0x0A { end -= 1 }
                        if end > start, body[end - 1] == 0x0D { end -= 1 }
                        sections.append(body[start..<max(start, end)])
                    }
                    if isClose { sawClose = true; break }
                    currentStart = min(index + 1, body.endIndex)
                }
            }
            lineStart = index + 1
        }
        if !sawClose {
            if let start = currentStart, start < body.endIndex { sections.append(body[start...]) }
            state.problems.append("multipart without a closing boundary")
        }
        return sections
    }
}
