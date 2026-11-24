import Foundation
import MailCore
import MailMIME

/// A message ready for the outbox: the exact bytes and the envelope, built once. A retry
/// sends these same bytes, so the Message-ID never changes (Architecture.md, Sending and drafts).
public struct ComposedMessage: Sendable, Hashable, Codable {
    /// Without angle brackets.
    public var messageID: String
    /// SMTP MAIL FROM.
    public var envelopeFrom: String
    /// SMTP RCPT TO: To, Cc and Bcc, each once.
    public var recipients: [String]
    /// The Bcc addresses among `recipients`. Kept only in the device-local outbox journal, for
    /// showing who it went to; never in `rawMessage`.
    public var bcc: [String]
    /// RFC 5322 + MIME, CRLF line endings. Contains no Bcc header.
    public var rawMessage: Data

    public init(messageID: String, envelopeFrom: String, recipients: [String], bcc: [String], rawMessage: Data) {
        self.messageID = messageID
        self.envelopeFrom = envelopeFrom
        self.recipients = recipients
        self.bcc = bcc
        self.rawMessage = rawMessage
    }
}

public enum ComposeError: Error, Equatable, Sendable, CustomStringConvertible {
    case noSender
    case noRecipients
    case invalidAddress(String)
    case missingAttachment(String)
    case tooLarge(bytes: Int, limit: Int)

    public var description: String {
        switch self {
        case .noSender: "Choose the account to send from."
        case .noRecipients: "Add at least one recipient."
        case .invalidAddress(let address): "“\(address)” is not an email address."
        case .missingAttachment(let name): "The attachment “\(name)” is missing from the draft."
        case .tooLarge(let bytes, let limit):
            "The message is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)); the limit is \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
        }
    }
}

/// Turns a draft into the bytes that are sent: multipart/alternative with the Markdown as
/// text/plain and HTML generated from it (``MarkdownHTML``), multipart/mixed around it when
/// there are attachments. Bcc goes into the envelope only.
public enum MessageComposer {
    /// The largest message the composer builds. Providers refuse more (iCloud and Gmail take
    /// about 20–25 MB after base64); the SMTP SIZE extension still has the last word.
    public static let maximumSize = 25 * 1024 * 1024

    public static func compose(_ draft: ComposeDraft, attachments: [OutgoingAttachment],
                               messageID: String? = nil, date: Date = Date()) throws -> ComposedMessage {
        guard let from = draft.from else { throw ComposeError.noSender }
        try validate(from.address)
        let to = try clean(draft.to), cc = try clean(draft.cc), bcc = try clean(draft.bcc)
        guard !(to.isEmpty && cc.isEmpty && bcc.isEmpty) else { throw ComposeError.noRecipients }

        let builder = MIMEBuilder(
            from: clean(name: from),
            to: to,
            cc: cc,
            bcc: bcc,
            subject: draft.subject,
            date: date,
            messageID: messageID,
            inReplyTo: draft.inReplyTo.flatMap(cleanID),
            references: draft.references.compactMap(cleanID),
            textBody: draft.body,
            htmlBody: MarkdownHTML.document(draft.body),
            attachments: attachments
        )
        let raw = builder.build()
        guard raw.count <= maximumSize else { throw ComposeError.tooLarge(bytes: raw.count, limit: maximumSize) }
        let bccKeys = Set(bcc.map { $0.address.lowercased() })
        return ComposedMessage(messageID: builder.messageID, envelopeFrom: from.address, recipients: builder.recipients,
                               bcc: builder.recipients.filter { bccKeys.contains($0.lowercased()) }, rawMessage: raw)
    }

    /// An address that is safe to put in a header and in SMTP's `<…>`: one `@`, a non-empty
    /// local part and domain, no spaces, control characters or the characters that would end
    /// the address early.
    public static func isValidAddress(_ address: String) -> Bool {
        let forbidden = CharacterSet(charactersIn: "<>()[]\\,;:\"").union(.whitespacesAndNewlines).union(.controlCharacters)
        guard address.rangeOfCharacter(from: forbidden) == nil, address.utf8.count <= 254 else { return false }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].utf8.count <= 64, !parts[1].isEmpty else { return false }
        let domain = parts[1]
        return !domain.hasPrefix(".") && !domain.hasSuffix(".") && !domain.contains("..")
    }

    static func validate(_ address: String) throws {
        guard isValidAddress(address) else { throw ComposeError.invalidAddress(address) }
    }

    /// Valid, each once, names without line breaks.
    static func clean(_ addresses: [MailAddress]) throws -> [MailAddress] {
        var seen = Set<String>()
        var out: [MailAddress] = []
        for address in addresses {
            let trimmed = MailAddress(name: address.name, address: address.address.trimmingCharacters(in: .whitespaces))
            try validate(trimmed.address)
            if seen.insert(trimmed.address.lowercased()).inserted { out.append(clean(name: trimmed)) }
        }
        return out
    }

    static func clean(name address: MailAddress) -> MailAddress {
        guard let name = address.name else { return address }
        let single = name.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return MailAddress(name: single.isEmpty ? nil : single, address: address.address)
    }

    /// A Message-ID from a received message, reduced to what may stand between `<` and `>`.
    static func cleanID(_ id: String) -> String? {
        let forbidden = CharacterSet(charactersIn: "<>").union(.whitespacesAndNewlines).union(.controlCharacters)
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: forbidden) == nil, trimmed.utf8.count <= 250 else { return nil }
        return trimmed
    }
}
