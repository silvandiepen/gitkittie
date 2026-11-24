import Foundation
import MailCore

// The attachment library (GKM-023; Features.md): every attachment across accounts, from the
// index alone. The bytes stay in `Mail/blobs/<sha256>` and are read only when the person asks
// (Quick Look of a quarantined copy, Save As), never while listing (ThreatModel §4).

/// The kinds the library filters by, from the media type and, because senders often say
/// `application/octet-stream`, the file name's extension.
public enum AttachmentKind: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case image, pdf, document, spreadsheet, presentation, archive, audio, video, calendar, other
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .image: "Images"
        case .pdf: "PDFs"
        case .document: "Documents"
        case .spreadsheet: "Spreadsheets"
        case .presentation: "Presentations"
        case .archive: "Archives"
        case .audio: "Audio"
        case .video: "Video"
        case .calendar: "Invitations"
        case .other: "Other"
        }
    }

    /// Media types (exact, or `type/%` prefixes) and extensions that make up a kind.
    var matches: (types: [String], extensions: [String]) {
        switch self {
        case .image: (["image/%"], ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg"])
        case .pdf: (["application/pdf"], ["pdf"])
        case .document:
            (["application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.%", "application/rtf", "text/rtf",
              "application/vnd.oasis.opendocument.text", "application/vnd.apple.pages", "text/plain", "text/markdown"],
             ["doc", "docx", "rtf", "odt", "pages", "txt", "md"])
        case .spreadsheet:
            (["application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument.spreadsheetml.%", "text/csv",
              "application/vnd.oasis.opendocument.spreadsheet", "application/vnd.apple.numbers"],
             ["xls", "xlsx", "csv", "ods", "numbers"])
        case .presentation:
            (["application/vnd.ms-powerpoint", "application/vnd.openxmlformats-officedocument.presentationml.%",
              "application/vnd.oasis.opendocument.presentation", "application/vnd.apple.keynote"],
             ["ppt", "pptx", "odp", "key"])
        case .archive:
            (["application/zip", "application/x-zip-compressed", "application/gzip", "application/x-gzip", "application/x-tar",
              "application/x-7z-compressed", "application/x-rar-compressed", "application/vnd.rar"],
             ["zip", "gz", "tgz", "tar", "7z", "rar"])
        case .audio: (["audio/%"], ["mp3", "m4a", "wav", "aiff", "aac", "flac"])
        case .video: (["video/%"], ["mp4", "mov", "m4v", "avi", "mkv", "webm"])
        case .calendar: (["text/calendar", "application/ics"], ["ics"])
        case .other: ([], [])
        }
    }

    /// The kind of one attachment, for its icon. The first kind that claims it wins.
    public static func of(mediaType: String, fileName: String) -> AttachmentKind {
        let type = mediaType.lowercased()
        let ext = (fileName as NSString).pathExtension.lowercased()
        for kind in allCases where kind != .other {
            let (types, extensions) = kind.matches
            if types.contains(where: { $0.hasSuffix("%") ? type.hasPrefix(String($0.dropLast())) : type == $0 }) { return kind }
            if !ext.isEmpty, extensions.contains(ext) { return kind }
        }
        return .other
    }
}

/// The library's filters. All narrow; none set lists everything that is not inline.
public struct AttachmentQuery: Equatable, Hashable, Sendable {
    public var kind: AttachmentKind?
    /// Words matched against the file name.
    public var name: String
    /// Words matched against the sender's name or address.
    public var sender: String
    public var account: MailAccountID?
    public var space: MailSpaceID?
    /// On or after this instant (the message's date).
    public var after: Date?
    public var before: Date?
    /// In bytes, inclusive.
    public var minimumSize: Int?
    /// Inline parts (signature logos, pictures in the HTML) are left out unless asked for.
    public var includeInline: Bool

    public init(kind: AttachmentKind? = nil, name: String = "", sender: String = "", account: MailAccountID? = nil,
                space: MailSpaceID? = nil, after: Date? = nil, before: Date? = nil, minimumSize: Int? = nil,
                includeInline: Bool = false) {
        self.kind = kind
        self.name = name
        self.sender = sender
        self.account = account
        self.space = space
        self.after = after
        self.before = before
        self.minimumSize = minimumSize
        self.includeInline = includeInline
    }
}

/// One attachment in one message, as the library lists it.
public struct AttachmentItem: Identifiable, Hashable, Sendable {
    public var id: String { message.rawValue + ":" + reference.blob }
    public var message: MailMessageID
    public var account: MailAccountID
    public var threadID: String
    public var subject: String?
    public var from: MailAddress?
    public var date: Date
    /// The blob, name, type and size, exactly as the message's Markdown records them.
    public var reference: AttachmentReference
    public var kind: AttachmentKind { AttachmentKind.of(mediaType: reference.mediaType, fileName: reference.fileName) }
}

extension MailIndex {
    /// Attachments matching `query`, newest message first, then by name.
    func attachments(matching query: AttachmentQuery, limit: Int, offset: Int) throws -> [AttachmentItem] {
        let (clause, values) = Self.attachmentClause(query)
        let statement = try database.prepare("""
            SELECT m.local_id, m.account_id, m.thread_id, m.subject, m.from_name, m.from_address, m.sort_date,
                   b.blob, b.file_name, b.media_type, b.size, b.inline, b.content_id
            FROM message_blobs b JOIN messages m ON m.local_id = b.local_id
            WHERE \(clause)
            ORDER BY m.sort_date DESC, m.local_id, b.file_name, b.blob LIMIT ? OFFSET ?
            """).bind(values + [.int(Int64(limit)), .int(Int64(offset))])
        var items: [AttachmentItem] = []
        while try statement.step() {
            guard let raw = statement.text(0), let id = MailMessageID(raw), let account = statement.text(1), let blob = statement.text(7)
            else { continue }
            let from = statement.text(5).map { MailAddress(name: statement.text(4), address: $0) }
            let reference = AttachmentReference(blob: blob, fileName: statement.text(8) ?? "", mediaType: statement.text(9) ?? "",
                                                size: statement.int(10), inline: statement.int(11) != 0, contentId: statement.text(12))
            items.append(AttachmentItem(message: id, account: MailAccountID(account), threadID: statement.text(2) ?? raw,
                                        subject: statement.text(3), from: from, date: Date(timeIntervalSince1970: statement.double(6)),
                                        reference: reference))
        }
        return items
    }

    /// How many attachments match, and their total size in bytes.
    func attachmentTotals(matching query: AttachmentQuery) throws -> (count: Int, bytes: Int) {
        let (clause, values) = Self.attachmentClause(query)
        let statement = try database.prepare("""
            SELECT count(*), coalesce(sum(b.size), 0) FROM message_blobs b JOIN messages m ON m.local_id = b.local_id WHERE \(clause)
            """).bind(values)
        return try statement.step() ? (statement.int(0), statement.int(1)) : (0, 0)
    }

    static func attachmentClause(_ query: AttachmentQuery) -> (String, [SQLiteValue]) {
        var clauses = ["1"]
        var values: [SQLiteValue] = []
        if !query.includeInline { clauses.append("b.inline = 0") }
        if let kind = query.kind {
            if kind == .other {
                let all = AttachmentKind.allCases.filter { $0 != .other }.map(kindCondition)
                clauses.append("NOT (" + all.map(\.0).joined(separator: " OR ") + ")")
                values += all.flatMap(\.1)
            } else {
                let (condition, kindValues) = kindCondition(kind)
                clauses.append(condition)
                values += kindValues
            }
        }
        for word in words(query.name) {
            clauses.append("lower(b.file_name) LIKE ? ESCAPE '\\'")
            values.append(.text("%" + likeEscaped(word) + "%"))
        }
        for word in words(query.sender) {
            clauses.append("(lower(coalesce(m.from_name, '')) LIKE ? ESCAPE '\\' OR lower(coalesce(m.from_address, '')) LIKE ? ESCAPE '\\')")
            values += [.text("%" + likeEscaped(word) + "%"), .text("%" + likeEscaped(word) + "%")]
        }
        if let account = query.account { clauses.append("m.account_id = ?"); values.append(.text(account.rawValue)) }
        if let space = query.space {
            clauses.append("EXISTS (SELECT 1 FROM space_members s WHERE s.local_id = m.local_id AND s.space_id = ?)")
            values.append(.text(space.rawValue))
        }
        if let after = query.after { clauses.append("m.sort_date >= ?"); values.append(.double(after.timeIntervalSince1970)) }
        if let before = query.before { clauses.append("m.sort_date < ?"); values.append(.double(before.timeIntervalSince1970)) }
        if let minimum = query.minimumSize { clauses.append("b.size >= ?"); values.append(.int(Int64(minimum))) }
        return (clauses.joined(separator: " AND "), values)
    }

    private static func kindCondition(_ kind: AttachmentKind) -> (String, [SQLiteValue]) {
        let (types, extensions) = kind.matches
        var parts: [String] = []
        var values: [SQLiteValue] = []
        for type in types {
            if type.hasSuffix("%") { parts.append("b.media_type LIKE ?") } else { parts.append("b.media_type = ?") }
            values.append(.text(type))
        }
        for ext in extensions {
            parts.append("lower(b.file_name) LIKE ?")
            values.append(.text("%." + ext))
        }
        return ("(" + parts.joined(separator: " OR ") + ")", values)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// `%`, `_` and `\` in the person's text match themselves, not as wildcards.
    static func likeEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }
}
