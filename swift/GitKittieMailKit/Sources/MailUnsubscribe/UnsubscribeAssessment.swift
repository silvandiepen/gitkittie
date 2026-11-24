import Foundation
import MailClassifier
import MailCore

// Unsubscribe, safely (GKM-020; ThreatModel §9; MAIL-056). This file only reads headers that are
// already stored and decides what may be offered. It never touches the network: the one request
// it allows is sent by `OneClickUnsubscriber`, and only after you approved that request.

/// How an unsubscribe would be done.
public enum UnsubscribeMethod: Sendable, Equatable, Hashable, Codable {
    /// RFC 8058: one POST of `List-Unsubscribe=One-Click` to this HTTPS URL, after you approve it.
    case oneClick(URL)
    /// A message to this address, previewed, then sent through the outbox like any other.
    case mailto(address: String, subject: String, body: String)
    /// A web page you finish yourself, in your browser, with a warning. Never fetched by the app.
    case manual(URL)

    public var kind: String {
        switch self {
        case .oneClick: "one-click"
        case .mailto: "mailto"
        case .manual: "manual"
        }
    }

    /// The URL or address, for the ledger and the approval sheet.
    public var target: String {
        switch self {
        case .oneClick(let url), .manual(let url): url.absoluteString
        case .mailto(let address, _, _): address
        }
    }
}

/// Why a URL in List-Unsubscribe is not one the app will contact.
public enum EndpointProblem: String, Sendable, Equatable, Codable, CaseIterable {
    case notHTTPS
    case credentialsInURL
    case ipAddressHost
    case localHost
    case nonStandardPort
    case internationalisedHost
    case lookalikeHost
    case tooLong
    case unreadable

    public var explanation: String {
        switch self {
        case .notHTTPS: "The link isn’t encrypted (not https)."
        case .credentialsInURL: "The link carries a user name or password."
        case .ipAddressHost: "The link goes to a bare IP address, not a named site."
        case .localHost: "The link points into your own network or computer."
        case .nonStandardPort: "The link uses an unusual port."
        case .internationalisedHost: "The link’s address uses lookalike characters."
        case .lookalikeHost: "The link’s address imitates a site you know."
        case .tooLong: "The link is unusually long."
        case .unreadable: "The link can’t be read."
        }
    }
}

/// Which endpoints the app may contact. The standard policy is the only one the app uses; tests
/// add their own loopback server, which the standard policy refuses (`localHost`, `notHTTPS`).
public struct EndpointPolicy: Sendable, Equatable {
    /// Loopback ports that may be contacted over plain HTTP. Empty in the app.
    public var loopbackHTTPPorts: Set<Int>
    /// Organisations you trust; an endpoint imitating one of them is refused.
    public var trustedOrganisations: Set<String>

    public init(loopbackHTTPPorts: Set<Int> = [], trustedOrganisations: Set<String> = []) {
        self.loopbackHTTPPorts = loopbackHTTPPorts
        self.trustedOrganisations = trustedOrganisations
    }

    public static let standard = EndpointPolicy()

    /// Checks a URL before it is offered and again right before it is contacted.
    public func problem(with url: URL) -> EndpointProblem? {
        guard url.absoluteString.count <= 2_048 else { return .tooLong }
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return .unreadable }
        if url.user != nil || url.password != nil { return .credentialsInURL }
        if isTestLoopback(url, scheme: scheme, host: host) { return nil }
        guard scheme == "https" else { return .notHTTPS }
        if let port = url.port, port != 443 { return .nonStandardPort }
        if Self.isIPAddress(host) { return .ipAddressHost }
        if Self.isLocal(host) { return .localHost }
        if host.split(separator: ".").contains(where: { $0.hasPrefix("xn--") }) { return .internationalisedHost }
        if DomainCheck.lookalikeTarget(ofHost: host, trusted: trustedOrganisations) != nil { return .lookalikeHost }
        return nil
    }

    private func isTestLoopback(_ url: URL, scheme: String, host: String) -> Bool {
        guard scheme == "http", host == "127.0.0.1", let port = url.port else { return false }
        return loopbackHTTPPorts.contains(port)
    }

    static func isIPAddress(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare.contains(":") { return true } // IPv6
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        // Dotted quads, and the short and numeric forms URL parsers also accept (http://2130706433/).
        return !parts.isEmpty && parts.allSatisfy { part in
            !part.isEmpty && (part.allSatisfy(\.isNumber) || (part.lowercased().hasPrefix("0x") && part.dropFirst(2).allSatisfy(\.isHexDigit)))
        }
    }

    static func isLocal(_ host: String) -> Bool {
        let host = host.hasSuffix(".") ? String(host.dropLast()) : host
        if !host.contains(".") { return true }
        let localSuffixes = [".local", ".localhost", ".internal", ".lan", ".home.arpa", ".intranet", ".corp"]
        return host == "localhost" || localSuffixes.contains { host.hasSuffix($0) }
    }
}

/// What the app may offer for one sender or list, decided from stored headers and the verdict.
public struct UnsubscribeAssessment: Sendable, Equatable {
    public enum Refusal: Sendable, Equatable {
        /// Spam, phishing or suspicious: unsubscribing would confirm your address. Report it as
        /// junk, or mute it, instead.
        case risky(MailRisk)
        /// The sender's identity looks forged (a lookalike domain, a pretend display name, failed authentication).
        case doubtfulSender
        /// No List-Unsubscribe header.
        case noHeader
        /// A List-Unsubscribe header without a mailing list around it (no List-ID, no one-click).
        case noListContext
        /// Every link or address in it was refused.
        case nothingUsable([EndpointProblem])
    }

    public enum Outcome: Sendable, Equatable {
        case offer(UnsubscribeMethod, alternatives: [UnsubscribeMethod])
        case refused(Refusal)
    }

    public var outcome: Outcome
    /// Things to know before approving: the request goes to another organisation (a mailing
    /// service), the list's identity doesn't match the sender, a link was refused.
    public var notes: [String]

    public init(outcome: Outcome, notes: [String]) {
        self.outcome = outcome
        self.notes = notes
    }

    public var method: UnsubscribeMethod? {
        if case .offer(let method, _) = outcome { return method }
        return nil
    }

    /// True when the mail should be reported as junk instead.
    public var suggestsReportingJunk: Bool {
        switch outcome {
        case .refused(.risky), .refused(.doubtfulSender): true
        default: false
        }
    }
}

/// Decides whether to offer an unsubscribe, and how. Pure: headers in, a decision out.
public enum UnsubscribeAssessor {
    /// Reasons that mean the sender may not be who it says it is.
    static let doubtfulReasons: Set<ReasonCode> = [.authTrustedFail, .displayNameSpoof, .lookalikeSender, .lookalikeLink, .linkTextMismatch]

    /// - Parameters:
    ///   - headers: the stored message's header fields (List-Unsubscribe, List-Unsubscribe-Post, List-ID).
    ///   - risk, reasons: the verdict of that message.
    ///   - senderAddress: its From address.
    public static func assess(headers: [String: String], risk: MailRisk, reasons: [ReasonCode], senderAddress: String?,
                              policy: EndpointPolicy = .standard) -> UnsubscribeAssessment {
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if risk != .none { return UnsubscribeAssessment(outcome: .refused(.risky(risk)), notes: []) }
        if !doubtfulReasons.isDisjoint(with: reasons) { return UnsubscribeAssessment(outcome: .refused(.doubtfulSender), notes: []) }
        guard let unsubscribe = header("List-Unsubscribe"), !unsubscribe.isEmpty else {
            return UnsubscribeAssessment(outcome: .refused(.noHeader), notes: [])
        }
        let listID = header("List-ID")
        // RFC 8058: exactly this value, nothing else, makes the HTTPS link a one-click endpoint.
        let oneClickPost = header("List-Unsubscribe-Post").map { $0.replacingOccurrences(of: " ", with: "") == "List-Unsubscribe=One-Click" } ?? false
        guard listID != nil || oneClickPost else { return UnsubscribeAssessment(outcome: .refused(.noListContext), notes: []) }

        let senderOrganisation = senderAddress.flatMap(DomainCheck.domain(ofAddress:)).map(DomainCheck.organisationDomain(of:))
        var notes: [String] = []
        if let listID, let listHost = listHost(listID), let senderOrganisation,
           DomainCheck.organisationDomain(of: listHost) != senderOrganisation {
            notes.append("The list (\(listHost)) is run from another domain than the sender (\(senderOrganisation)); mailing services often do this.")
        }
        var https: [URL] = []
        var mailtos: [UnsubscribeMethod] = []
        var problems: [EndpointProblem] = []
        for entry in entries(unsubscribe) {
            let lower = entry.lowercased()
            if lower.hasPrefix("mailto:") {
                if let mailto = parseMailto(entry) { mailtos.append(mailto) } else { problems.append(.unreadable) }
            } else if let url = URL(string: entry), url.scheme != nil {
                if let problem = policy.problem(with: url) { problems.append(problem) } else { https.append(url) }
            } else {
                problems.append(.unreadable)
            }
        }
        if !problems.isEmpty {
            notes.append("Left out: " + Set(problems).map(\.explanation).sorted().joined(separator: " "))
        }
        var methods: [UnsubscribeMethod] = []
        if oneClickPost, let url = https.first { methods.append(.oneClick(url)) }
        methods += mailtos
        if !oneClickPost { methods += https.map(UnsubscribeMethod.manual) }
        guard let primary = methods.first else {
            return UnsubscribeAssessment(outcome: .refused(.nothingUsable(problems)), notes: notes)
        }
        if case .oneClick(let url) = primary, let host = url.host?.lowercased(), let senderOrganisation,
           DomainCheck.organisationDomain(of: host) != senderOrganisation {
            notes.append("The request goes to \(DomainCheck.organisationDomain(of: host)), not \(senderOrganisation): probably the list’s mailing service.")
        }
        return UnsubscribeAssessment(outcome: .offer(primary, alternatives: Array(methods.dropFirst())), notes: notes)
    }

    /// RFC 2369: a comma-separated list of `<URI>`s. Text outside angle brackets is ignored.
    static func entries(_ value: String) -> [String] {
        var result: [String] = []
        var rest = Substring(value)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            let entry = rest[rest.index(after: open)..<close].filter { !$0.isWhitespace }
            if !entry.isEmpty { result.append(String(entry)) }
            rest = rest[rest.index(after: close)...]
        }
        return Array(result.prefix(8))
    }

    static func listHost(_ listID: String) -> String? {
        let inner: Substring
        if let open = listID.lastIndex(of: "<"), let close = listID[open...].firstIndex(of: ">") {
            inner = listID[listID.index(after: open)..<close]
        } else {
            inner = Substring(listID)
        }
        let host = inner.trimmingCharacters(in: .whitespaces).lowercased()
        return host.contains(".") ? host : nil
    }

    /// `mailto:address?subject=…&body=…`. One plain address; only subject and body are kept,
    /// never other headers (cc, bcc, from) a sender could slip in.
    static func parseMailto(_ entry: String) -> UnsubscribeMethod? {
        let body = entry.dropFirst("mailto:".count)
        let parts = body.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawAddress = parts.first, let address = String(rawAddress).removingPercentEncoding?.lowercased(),
              isPlainAddress(address) else { return nil }
        var subject = "unsubscribe", text = ""
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard kv.count == 2, let value = String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { continue }
                switch kv[0].lowercased() {
                case "subject": subject = String(value.filter { !$0.isNewline }.prefix(200))
                case "body": text = String(value.prefix(2_000))
                default: continue
                }
            }
        }
        return .mailto(address: address, subject: subject.isEmpty ? "unsubscribe" : subject, body: text)
    }

    static func isPlainAddress(_ address: String) -> Bool {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), address.count <= 254 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".!#$%&'*+-/=^_`{|}~@"))
        return address.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
            && !EndpointPolicy.isIPAddress(String(parts[1])) && !EndpointPolicy.isLocal(String(parts[1]))
    }
}
