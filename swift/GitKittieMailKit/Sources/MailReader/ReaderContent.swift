import Foundation
import MailClassifier
import MailCore
import MailHTML
import MailStore

/// What is off about who a message says it is from (ThreatModel §3). The display name is free
/// text the sender wrote; the reader always shows the address beside it, and these warnings
/// say when the two disagree. Authentication results never produce a positive badge here.
public enum SenderWarning: Equatable, Hashable, Sendable {
    /// "service@bank.example <x@other.example>": the name carries a different address.
    case nameContainsOtherAddress(String)
    /// "bank.example Support <x@other.example>": the name names a different domain.
    case nameMentionsOtherDomain(String)
    /// Replies would go to a different domain than the sender's.
    case replyToDiffers(String)
    case multipleSenders
    case noSender

    public var message: String {
        switch self {
        case .nameContainsOtherAddress(let address): "The name shows the address \(address), but the message is from a different one."
        case .nameMentionsOtherDomain(let domain): "The name mentions \(domain), but the message comes from another domain."
        case .replyToDiffers(let address): "Replies go to \(address), not to the sender."
        case .multipleSenders: "This message names more than one sender."
        case .noSender: "This message has no readable sender."
        }
    }
}

/// The sender as the reader shows it: the address always, the name as the sender wrote it.
public struct SenderAssessment: Equatable, Sendable {
    public var address: String?
    public var name: String?
    /// The registrable domain of the address, the part worth reading.
    public var domain: String?
    public var warnings: [SenderWarning]

    public static func assess(from: [MailAddress], replyTo: [MailAddress]) -> SenderAssessment {
        guard let sender = from.first else {
            return SenderAssessment(address: nil, name: nil, domain: nil, warnings: [.noSender])
        }
        var warnings: [SenderWarning] = []
        if from.count > 1 { warnings.append(.multipleSenders) }
        let address = sender.address.lowercased()
        let domain = DomainCheck.domain(ofAddress: address).map { DomainCheck.organisationDomain(of: Punycode.asciiHost($0)) }
        let name = sender.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let name {
            if let shown = firstAddress(in: name), shown != address {
                warnings.append(.nameContainsOtherAddress(shown))
            } else if let shownHost = LinkInspector.hostShown(in: name), let domain,
                      DomainCheck.organisationDomain(of: Punycode.asciiHost(shownHost)) != domain {
                warnings.append(.nameMentionsOtherDomain(shownHost))
            }
        }
        if let domain {
            for reply in replyTo {
                let replyDomain = DomainCheck.domain(ofAddress: reply.address).map { DomainCheck.organisationDomain(of: Punycode.asciiHost($0)) }
                if let replyDomain, replyDomain != domain {
                    warnings.append(.replyToDiffers(reply.address.lowercased()))
                    break
                }
            }
        }
        return SenderAssessment(address: address, name: name, domain: domain, warnings: warnings)
    }

    static func firstAddress(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"[^\s<>"'(),;:@]+@[^\s<>"'(),;:@]+\.[^\s<>"'(),;:@]+"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return text[range].lowercased()
    }
}

/// Everything the reader shows for one message, worked out without touching the network.
public struct ReaderContent: Sendable {
    public enum Body: Sendable {
        case plain(String)
        case html(SanitizedHTML)
        case empty
    }

    public var body: Body
    /// The plain-text version, when the message has both and HTML is shown.
    public var plainAlternative: String?
    public var sender: SenderAssessment
    /// Every link in the HTML, assessed, by index (the `x-gkm-link:<n>` the web view reports).
    public var links: [LinkAssessment]
    /// Attachments to list: everything except inline parts the HTML shows itself.
    public var attachments: [AttachmentReference]
    /// Inline images by Content-ID, served to the web view from the store's blobs.
    public var inlineParts: [String: AttachmentReference]
    public var parseProblems: [String]

    public var suspiciousLinkCount: Int { links.filter(\.isSuspicious).count }

    /// - Parameters:
    ///   - allowRemoteImages: the user chose to load remote images for this sender or message.
    ///   - preferPlainText: show the text version even when there is HTML.
    public static func make(from message: StoredMessage, allowRemoteImages: Bool = false, preferPlainText: Bool = false) -> ReaderContent {
        let front = message.front
        let sender = SenderAssessment.assess(from: front.from, replyTo: front.replyTo)
        let inline = Dictionary(front.attachments.compactMap { attachment -> (String, AttachmentReference)? in
            guard let cid = attachment.contentId, attachment.mediaType.lowercased().hasPrefix("image/") else { return nil }
            return (cid, attachment)
        }, uniquingKeysWith: { first, _ in first })

        var body = Body.empty
        var links: [LinkAssessment] = []
        var used: Set<String> = []
        let text = message.textBody.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if let html = message.htmlBody, !(preferPlainText && text != nil) {
            let sanitized = HTMLSanitizer.sanitize(html, policy: .init(allowRemoteImages: allowRemoteImages, contentIDs: Set(inline.keys)))
            body = .html(sanitized)
            links = sanitized.links.map { LinkInspector.assess($0, senderAddress: sender.address) }
            used = sanitized.contentIDs
        } else if let text {
            body = .plain(text)
        }
        let attachments = front.attachments.filter { attachment in
            guard attachment.inline, let cid = attachment.contentId else { return true }
            return !used.contains(cid)
        }
        return ReaderContent(body: body, plainAlternative: message.htmlBody != nil ? text : nil, sender: sender, links: links,
                             attachments: attachments, inlineParts: inline.filter { used.contains($0.key) },
                             parseProblems: message.parseProblems)
    }
}

/// The per-sender "Load remote images" choice (GKM-012), kept on this device in
/// `<device folder>/preferences/remote-images.json`. Keyed by the sender's address, which is
/// spoofable: the reader ignores the choice for any message with a sender warning.
public actor RemoteContentPreferences {
    private struct File: Codable {
        var version = 1
        var senders: [String: Date] = [:]
    }

    private let url: URL
    private var file: File

    public init(deviceFolder: URL) {
        url = deviceFolder.appendingPathComponent("preferences", isDirectory: true).appendingPathComponent("remote-images.json")
        file = (try? JSONDecoder.iso.decode(File.self, from: Data(contentsOf: url))) ?? File()
    }

    public func allowsRemoteImages(from address: String) -> Bool {
        file.senders[address.lowercased()] != nil
    }

    public func setAllowsRemoteImages(_ allow: Bool, from address: String, now: Date = Date()) throws {
        file.senders[address.lowercased()] = allow ? now : nil
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.iso.encode(file).write(to: url, options: .atomic)
    }

    public var senders: [String] { file.senders.keys.sorted() }
}

private extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
