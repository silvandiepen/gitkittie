import Foundation
import MailCore
import MailMIME

/// Builds the draft for Reply, Reply All and Forward from a received message
/// (Architecture.md, Storage and identity: a reply keeps recipients, Reply-To, the account's
/// identity and the standard headers, and never exposes internal tags).
///
/// The rules:
/// - **Reply** goes to Reply-To when the message has one, otherwise to From. Replying to a
///   message you sent yourself goes to its original recipients instead.
/// - **Reply All** adds everyone in To and Cc, minus your own addresses and anyone already
///   addressed, each address once (compared without case).
/// - The identity is the one of your addresses the message was sent to, so a reply to your
///   alias comes from that alias; otherwise the account's main address.
/// - In-Reply-To is the original Message-ID; References is the original's References (or its
///   In-Reply-To) plus its Message-ID, trimmed to the first and the last 19 ids.
/// - The original is quoted as Markdown block quotes under an attribution line.
/// - **Forward** starts a new conversation: no recipients, no In-Reply-To, the original text
///   under a forwarded-message header, and the original's attachments.
public struct ReplyBuilder: Sendable {
    /// Every address that is the user's own on this account: the main one and the aliases.
    public var ownAddresses: [MailAddress]
    public var account: MailAccountID?
    public var timeZone: TimeZone
    public var locale: Locale

    /// The most ids References keeps (RFC 5322 3.6.4 allows trimming; the first is kept so the
    /// thread's root stays known).
    public static let maximumReferences = 20

    public init(ownAddresses: [MailAddress], account: MailAccountID? = nil,
                timeZone: TimeZone = .current, locale: Locale = Locale(identifier: "en_US_POSIX")) {
        self.ownAddresses = ownAddresses
        self.account = account
        self.timeZone = timeZone
        self.locale = locale
    }

    public enum Mode: Sendable { case reply, replyAll }

    public func reply(to original: MIMEMessage, mode: Mode, source: MailMessageID? = nil) -> ComposeDraft {
        let own = Set(ownAddresses.map { Self.key($0.address) })
        let from = original.from
        let wroteItMyself = !from.isEmpty && from.allSatisfy { own.contains(Self.key($0.address)) }

        var to: [MailAddress]
        var cc: [MailAddress] = []
        if wroteItMyself {
            // A reply to your own message continues the conversation with its recipients.
            to = original.to
            if mode == .replyAll { cc = original.cc }
        } else {
            to = original.replyTo.isEmpty ? from : original.replyTo
            if mode == .replyAll { cc = original.to + original.cc }
        }
        to = Self.unique(to, excluding: own)
        if to.isEmpty, !wroteItMyself { to = Self.unique(from, excluding: []) }
        cc = Self.unique(cc, excluding: own.union(to.map { Self.key($0.address) }))

        var references = original.references.isEmpty ? original.inReplyTo : original.references
        if let id = original.messageID { references.append(id) }
        references = Self.trimmed(Self.uniqueIDs(references))

        let draft = ComposeDraft(
            account: account,
            from: identity(for: original),
            to: to,
            cc: cc,
            subject: Self.prefixed(original.subject ?? "", with: "Re:", recognising: ["re", "aw", "sv", "antw", "vs", "odp"]),
            body: "\n\n" + quote(original),
            kind: mode == .reply ? .reply : .replyAll,
            inReplyTo: original.messageID,
            references: references,
            source: source
        )
        return draft
    }

    /// The forward draft and the original's attachments to add to it.
    public func forward(_ original: MIMEMessage, source: MailMessageID? = nil) -> (draft: ComposeDraft, attachments: [OutgoingAttachment]) {
        var header = ["---------- Forwarded message ----------"]
        if let from = original.from.first { header.append("From: \(Self.display(from))") }
        if let date = original.date { header.append("Date: \(formatted(date))") }
        header.append("Subject: \(original.subject ?? "")")
        if !original.to.isEmpty { header.append("To: \(original.to.map(Self.display).joined(separator: ", "))") }
        if !original.cc.isEmpty { header.append("Cc: \(original.cc.map(Self.display).joined(separator: ", "))") }
        // Two spaces end a Markdown line with a hard break, so the header block stays one line
        // per field in the HTML part too.
        let headerBlock = header.map { Self.escapeMarkdownLine($0) + "  " }.joined(separator: "\n")
        let body = "\n\n" + headerBlock + "\n\n" + Self.bodyText(of: original)

        let attachments = original.attachments.map { part in
            OutgoingAttachment(filename: part.filename ?? "attachment", mimeType: Self.safeMIMEType(part.mimeType), data: part.body)
        }
        let draft = ComposeDraft(
            account: account,
            from: identity(for: original),
            subject: Self.prefixed(original.subject ?? "", with: "Fwd:", recognising: ["fwd", "fw", "wg", "tr", "doorst"]),
            body: body,
            kind: .forward,
            source: source
        )
        return (draft, attachments)
    }

    // MARK: - Pieces

    /// Which of the user's addresses the message reached: that one answers.
    func identity(for original: MIMEMessage) -> MailAddress? {
        let addressed = original.to + original.cc + original.headers.all("Delivered-To").flatMap(AddressParser.parseList)
            + original.from
        for candidate in addressed {
            if let mine = ownAddresses.first(where: { Self.key($0.address) == Self.key(candidate.address) }) { return mine }
        }
        return ownAddresses.first
    }

    func quote(_ original: MIMEMessage) -> String {
        let who = original.from.first.map(Self.display) ?? "Someone"
        let attribution = original.date.map { "On \(formatted($0)), \(who) wrote:" } ?? "\(who) wrote:"
        let text = Self.bodyText(of: original).trimmingCharacters(in: .newlines)
        let quoted = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
        return Self.escapeMarkdownLine(attribution) + "\n\n" + quoted + "\n"
    }

    func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, d MMM yyyy 'at' HH:mm"
        return formatter.string(from: date)
    }

    /// The readable text of a message: its text/plain part, or its HTML reduced to text.
    static func bodyText(of message: MIMEMessage) -> String {
        if let text = message.textBody { return normalizedLines(text) }
        if let html = message.htmlBody { return normalizedLines(HTMLText.plainText(html)) }
        return ""
    }

    static func normalizedLines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func display(_ address: MailAddress) -> String {
        guard let name = address.name, !name.isEmpty, name != address.address else { return "<\(address.address)>" }
        return "\(name) <\(address.address)>"
    }

    /// Addresses in a forwarded-message header must not turn into Markdown (an `<a@b>` is an
    /// autolink, a leading `#` a heading); the text part keeps them as written.
    static func escapeMarkdownLine(_ line: String) -> String {
        var out = ""
        for character in line {
            if "\\`*_[]<>#".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// "Re: Re: Re:" stays "Re:"; a subject that already starts with any language's reply
    /// prefix is left alone.
    static func prefixed(_ subject: String, with prefix: String, recognising known: [String]) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()
        for word in known where lowered.hasPrefix(word + ":") || lowered.hasPrefix(word + " :") {
            return trimmed
        }
        return trimmed.isEmpty ? prefix : "\(prefix) \(trimmed)"
    }

    static func key(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Each address once (first spelling wins), none of `excluding`, none without an `@`.
    static func unique(_ addresses: [MailAddress], excluding: Set<String>) -> [MailAddress] {
        var seen = excluding
        var out: [MailAddress] = []
        for address in addresses where address.address.contains("@") {
            if seen.insert(key(address.address)).inserted { out.append(address) }
        }
        return out
    }

    static func uniqueIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    static func trimmed(_ references: [String]) -> [String] {
        guard references.count > maximumReferences, let first = references.first else { return references }
        return [first] + references.suffix(maximumReferences - 1)
    }

    /// A Content-Type from a received message, reduced to `type/subtype` of safe characters,
    /// so it can go back into a header unchanged.
    static func safeMIMEType(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "!#$&-^_.+"))
        let parts = value.lowercased().split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            return "application/octet-stream"
        }
        return value.lowercased()
    }
}

/// HTML reduced to readable text for quoting: tags dropped, block ends become line breaks,
/// common entities decoded. Never rendered, so nothing in it can run.
enum HTMLText {
    static func plainText(_ html: String) -> String {
        var text = html
        // Content that is never text.
        for tag in ["script", "style", "head", "title"] {
            text = text.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)\\s*>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</(p|div|h[1-6]|li|tr|blockquote)\\s*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        for line in lines where !(line.isEmpty && (out.last?.isEmpty ?? true)) { out.append(line) }
        return out.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}
