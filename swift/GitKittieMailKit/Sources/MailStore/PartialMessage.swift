import Foundation
import MailCore
import MailMIME

// Partial messages (GKM-036, MAIL-062): a message whose large attachments were left at the
// provider. The sync fetches its header, its structure (IMAP BODYSTRUCTURE), every part's MIME
// header and every part at or below the threshold; what is above it is fetched when someone
// opens it, or when the message is completed (pinned, exported, forwarded).
//
// A partial message is never an original. It lives in the device folder, not the mail folder
// (`<device>/partial/<account>/<id>.partial.{json,eml,md}`): the `.partial.eml` is a skeleton
// made of the fetched sections with the left-out parts empty, so search, threads, the reader's
// text and classification work on it; it is never exported, never hash-checked as an original
// and never offered as one. Completing a message downloads its whole original once and writes
// it like any other message: the `.eml` byte for byte as the provider has it, under the same
// local id, after which the partial files go.

/// One part of a message's MIME structure, as the provider describes it (IMAP BODYSTRUCTURE).
public struct MessagePart: Codable, Hashable, Sendable {
    /// The IMAP part specifier: "1", "2.1". The top level of a single-part message is "1"; the
    /// top level of a multipart message is "" (its header is the message header).
    public var section: String
    /// Lowercased `type/subtype`.
    public var mediaType: String
    /// The multipart boundary, for multiparts.
    public var boundary: String?
    /// Lowercased Content-Transfer-Encoding.
    public var encoding: String?
    /// The part's body size at the provider, in octets, as encoded.
    public var size: Int
    /// The name the sender gave the file, as the provider reports it (raw, not yet made safe).
    public var fileName: String?
    /// Lowercased Content-Disposition (`attachment`, `inline`).
    public var disposition: String?
    public var contentID: String?
    public var parts: [MessagePart]

    public init(section: String, mediaType: String, boundary: String? = nil, encoding: String? = nil, size: Int,
                fileName: String? = nil, disposition: String? = nil, contentID: String? = nil, parts: [MessagePart] = []) {
        self.section = section
        self.mediaType = mediaType.lowercased()
        self.boundary = boundary
        self.encoding = encoding?.lowercased()
        self.size = size
        self.fileName = fileName
        self.disposition = disposition?.lowercased()
        self.contentID = contentID
        self.parts = parts
    }

    public var isMultipart: Bool { mediaType.hasPrefix("multipart/") }

    /// Every leaf, depth first: the same order MailMIME lists them in.
    public var leaves: [MessagePart] { isMultipart ? parts.flatMap(\.leaves) : [self] }

    /// Every part below the top, depth first.
    var descendants: [MessagePart] { parts.flatMap { [$0] + $0.descendants } }

    /// The same rule as MailMIME's `MIMEPart.isAttachment`: only parts that would be listed as
    /// attachments may be left at the provider, so the text the reader and search use is always
    /// there.
    var isAttachment: Bool {
        if isMultipart { return false }
        if disposition == "attachment" || fileName != nil { return true }
        return !(mediaType.hasPrefix("text/") || mediaType.isEmpty) && mediaType != "message/delivery-status"
    }

    /// The decoded size, estimated from the encoded one (base64 carries 57 bytes per 78-byte line).
    var estimatedDecodedSize: Int {
        encoding == "base64" ? size * 57 / 78 : size
    }
}

/// What the sync fetched of a message it stores partially.
public struct SyncedPartialMessage: Sendable {
    /// The message header, exactly as the provider sends it (IMAP `BODY[HEADER]`).
    public var header: Data
    public var structure: MessagePart
    /// Fetched sections by name: `"1.MIME"` (a part's MIME header) and `"1"` (a part's body,
    /// still encoded), for every section ``PartialPlan/sections(of:threshold:)`` asked for.
    public var sections: [String: Data]
    /// The whole message's size at the provider (RFC822.SIZE).
    public var size: Int
    public var remote: RemoteLocation
    public var receivedAt: Date
    public var flags: MailMessageFlags

    public init(header: Data, structure: MessagePart, sections: [String: Data], size: Int, remote: RemoteLocation,
                receivedAt: Date, flags: MailMessageFlags) {
        self.header = header
        self.structure = structure
        self.sections = sections
        self.size = size
        self.remote = remote
        self.receivedAt = receivedAt
        self.flags = flags
    }
}

extension SyncedPartialMessage {
    /// The bytes storing it adds to the account's downloaded total (its skeleton): what the
    /// sync weighs against the history budget before storing it.
    public var storedSize: Int {
        (try? PartialPlan.skeleton(header: header, root: structure, sections: sections).count)
            ?? header.count + sections.values.reduce(0) { $0 + $1.count }
    }
}

/// Which parts of a message are left at the provider, and which sections a partial copy needs.
/// Plain functions, shared by the sync (what to fetch) and the store (what it was given).
public enum PartialPlan {
    /// Deepest structure a partial copy is made of; deeper messages are fetched whole.
    static let maximumDepth = 12
    /// Most parts a partial copy is made of; more and the message is fetched whole.
    static let maximumParts = 200

    /// The leaves left at the provider: attachments larger than `threshold` octets.
    public static func omitted(_ root: MessagePart, threshold: Int) -> [MessagePart] {
        root.leaves.filter { $0.isAttachment && $0.size > threshold }
    }

    /// The sections to fetch for a partial copy: the header; then, below every multipart that
    /// holds a left-out part, each child's MIME header and, for a child with nothing left out,
    /// its whole body (a multipart child as one unit, boundaries and all, so its exact bytes
    /// come with it). `nil` when the message should be fetched whole instead: nothing would be
    /// left out, or the structure is one a skeleton cannot be made from (a multipart without a
    /// boundary, too deep, too many parts).
    public static func sections(of root: MessagePart, threshold: Int) -> [String]? {
        guard isUsable(root), !omitted(root, threshold: threshold).isEmpty else { return nil }
        let left = Set(omitted(root, threshold: threshold).map(\.section))
        var sections = ["HEADER"]
        func walk(_ part: MessagePart) {
            guard part.isMultipart else {
                if !left.contains(part.section) { sections.append(part.section) }
                return
            }
            for child in part.parts {
                sections.append(child.section + ".MIME")
                if child.leaves.contains(where: { left.contains($0.section) }) { walk(child) } else { sections.append(child.section) }
            }
        }
        walk(root)
        return sections
    }

    /// True when every fetched MIME header declares the type the structure gives its part. A
    /// server that answers a section with the wrong part (GreenMail 2.1 returns a nested
    /// multipart's header for `1.1.MIME`) cannot give a faithful copy: fetch the message whole.
    public static func isConsistent(_ root: MessagePart, sections: [String: Data]) -> Bool {
        func check(_ part: MessagePart) -> Bool {
            if let mime = sections[part.section + ".MIME"] {
                let header = MIMEParser.parse(endingInBlankLine(mime)).headers
                let declared = header["Content-Type"].map { ParameterizedValue.parse($0).value.lowercased() } ?? "text/plain"
                if declared != part.mediaType { return false }
            }
            return part.parts.allSatisfy(check)
        }
        return root.parts.allSatisfy(check)
    }

    static func isUsable(_ root: MessagePart) -> Bool {
        func check(_ part: MessagePart, depth: Int) -> Bool {
            guard depth <= maximumDepth else { return false }
            if part.isMultipart {
                guard let boundary = part.boundary, !boundary.isEmpty, !part.parts.isEmpty else { return false }
                return part.parts.allSatisfy { check($0, depth: depth + 1) }
            }
            return part.parts.isEmpty
        }
        let count = root.descendants.count + 1
        return count <= maximumParts && check(root, depth: 0)
    }

    /// The skeleton: the header, then every part with its MIME header and, where it was fetched,
    /// its body; a part left at the provider is there with an empty body. Never an original.
    static func skeleton(header: Data, root: MessagePart, sections: [String: Data]) throws -> Data {
        var out = endingInBlankLine(header)
        if root.isMultipart {
            try appendMultipart(root, to: &out, sections: sections)
        } else {
            out.append(sections[root.section] ?? Data())
        }
        return out
    }

    private static func appendMultipart(_ part: MessagePart, to out: inout Data, sections: [String: Data]) throws {
        guard let boundary = part.boundary else { throw MailStoreError.unparseableMessage("multipart without a boundary") }
        for (offset, child) in part.parts.enumerated() {
            out.append(Data(((offset == 0 ? "" : "\r\n") + "--\(boundary)\r\n").utf8))
            guard let mime = sections[child.section + ".MIME"] else {
                throw MailStoreError.unparseableMessage("missing the MIME header of part \(child.section)")
            }
            out.append(endingInBlankLine(mime))
            if let whole = sections[child.section] {
                out.append(whole) // a leaf, or a multipart fetched as one unit
            } else if child.isMultipart {
                try appendMultipart(child, to: &out, sections: sections)
            }
        }
        out.append(Data("\r\n--\(boundary)--\r\n".utf8))
    }

    /// A header block as a parser needs it: ending in an empty line.
    static func endingInBlankLine(_ header: Data) -> Data {
        var header = header
        if header.suffix(4) == Data("\r\n\r\n".utf8) || header.suffix(2) == Data("\n\n".utf8) { return header }
        header.append(Data((header.suffix(2) == Data("\r\n".utf8) ? "\r\n" : "\r\n\r\n").utf8))
        return header
    }

    /// A part's body as fetched (encoded) → its bytes, decoded the way MailMIME decodes a part,
    /// so the hash is the one a complete original gives the same attachment.
    static func decode(_ body: Data, encoding: String?) -> Data {
        switch encoding {
        case "base64": TransferEncoding.decodeBase64(body)
        case "quoted-printable": TransferEncoding.decodeQuotedPrintable(body)
        default: body
        }
    }

    /// What identifies a partial copy, so the same message seen in a second folder (or again
    /// after a UIDVALIDITY reset) matches it instead of being stored twice: its exact header,
    /// size and structure, and every section fetched.
    static func signature(header: Data, size: Int, structure: MessagePart, sections: [String: Data]) throws -> String {
        var data = Data("gkm-partial-1\n\(size)\n".utf8)
        data.append(header)
        data.append(try JSONCoding.encoder.encode(structure))
        for name in sections.keys.sorted() {
            data.append(Data("\n\(name)\n\(Hashing.sha256Hex(sections[name]!))".utf8))
        }
        return Hashing.sha256Hex(data)
    }
}

/// `<device>/partial/<account>/<id>.partial.json`: what a partial copy is made of and what is
/// still at the provider. Device state; rewritten whole when a part is fetched or evicted.
struct PartialManifest: Codable, Equatable {
    static let format = 1

    var format: Int
    var id: MailMessageID
    var account: MailAccountID
    /// The whole message's size at the provider.
    var size: Int
    /// The length of the original's header (`BODY[HEADER]`): the original starts with exactly
    /// the skeleton's first `headerLength` bytes.
    var headerLength: Int
    var headerSha256: String
    var structure: MessagePart
    /// Sections left at the provider.
    var omitted: [String]
    /// Left-out sections fetched since, by section: the decoded bytes' SHA-256, in the cache.
    var fetched: [String: FetchedPart]
    var signature: String
    var received: Date
}

/// Where a partial message stands, for the reader, pinning and the on-demand fetch.
public struct PartialStatus: Equatable, Sendable {
    public var id: MailMessageID
    public var account: MailAccountID
    /// The whole message at the provider, in octets.
    public var size: Int
    /// Parts still only at the provider, with their encoded size.
    public var missing: [(section: String, size: Int)]
    /// Parts fetched on demand, held in the cache.
    public var fetched: [String: String]
    public var locations: [RemoteLocation]

    public var missingBytes: Int { missing.reduce(0) { $0 + $1.size } }

    public static func == (lhs: PartialStatus, rhs: PartialStatus) -> Bool {
        lhs.id == rhs.id && lhs.size == rhs.size && lhs.fetched == rhs.fetched && lhs.locations == rhs.locations
            && lhs.missing.map(\.section) == rhs.missing.map(\.section) && lhs.missing.map(\.size) == rhs.missing.map(\.size)
    }
}
