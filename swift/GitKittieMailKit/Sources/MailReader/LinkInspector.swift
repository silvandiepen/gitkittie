import Foundation
import MailClassifier
import MailHTML

/// Why a link deserves a second look before it opens (ThreatModel §2).
public enum LinkWarning: Equatable, Hashable, Sendable {
    /// The link's text names one domain; it goes to another.
    case textShowsOtherDomain(shown: String)
    /// The destination resembles the sender's domain without being it (either may be the fake).
    case lookalike(of: String)
    /// The host mixes alphabets in one label (Latin with Cyrillic, say).
    case mixedScripts
    /// The host uses non-ASCII characters (shown in its `xn--` form).
    case internationalizedHost
    /// The host is a bare IP address.
    case ipAddressHost
    /// `https://trusted.example@other.example/`: the part before `@` is not where it goes.
    case userInfoInURL
    /// Plain `http`: the page is not encrypted.
    case unencrypted
    /// `javascript:`, `data:`, `file:` or an app scheme: never opened.
    case blockedScheme(String)

    /// One sentence for the link sheet.
    public var message: String {
        switch self {
        case .textShowsOtherDomain(let shown): "The link text shows \(shown), but it goes somewhere else."
        case .lookalike(let target): "This looks like \(target), the sender’s domain, but it is a different one."
        case .mixedScripts: "The address mixes alphabets, a common way to imitate a known name."
        case .internationalizedHost: "The address uses non-Latin characters; its real form is shown."
        case .ipAddressHost: "The address is a bare IP number, not a name."
        case .userInfoInURL: "The text before “@” in this address is not where it goes."
        case .unencrypted: "The page is not encrypted (http)."
        case .blockedScheme(let scheme): "“\(scheme):” links are never opened from mail."
        }
    }

    /// Warnings that suggest deception, as opposed to information (`unencrypted`).
    public var isSuspicious: Bool {
        switch self {
        case .unencrypted, .internationalizedHost: false
        default: true
        }
    }
}

/// A link with its real destination worked out, ready to show before anything opens.
public struct LinkAssessment: Equatable, Sendable, Identifiable {
    public var id: Int { link.index }
    public var link: HTMLLink
    /// Lowercased scheme (`https`, `mailto`, …).
    public var scheme: String
    /// The host in ASCII (`xn--` for internationalized names), lowercased.
    public var host: String?
    /// The part of the host people should read (`example.com` in `login.example.com`).
    public var registrableDomain: String?
    /// The destination for display: scheme, ASCII host, path, query.
    public var displayDestination: String
    /// What can be opened: an `http(s)` or `mailto` URL rebuilt with the ASCII host.
    public var openURL: URL?
    public var warnings: [LinkWarning]

    public var isSuspicious: Bool { warnings.contains(where: \.isSuspicious) }
}

/// Works out where links really go and what is off about them. Pure: no lookups, no network.
public enum LinkInspector {
    /// - Parameter senderAddress: the From address, whose organisation domain lookalikes imitate.
    public static func assess(_ link: HTMLLink, senderAddress: String?) -> LinkAssessment {
        let href = link.href.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = String(String.UnicodeScalarView(href.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }))
        let scheme = cleaned.firstIndex(of: ":").map { cleaned[..<$0].lowercased() } ?? ""
        var warnings: [LinkWarning] = []

        guard link.isAllowedScheme, ["http", "https", "mailto"].contains(scheme) else {
            warnings.append(.blockedScheme(scheme.isEmpty ? "unknown" : scheme))
            return LinkAssessment(link: link, scheme: scheme, host: nil, registrableDomain: nil,
                                  displayDestination: String(href.prefix(300)), openURL: nil, warnings: warnings)
        }

        if scheme == "mailto" {
            let address = cleaned.dropFirst("mailto:".count).split(separator: "?").first.map { String($0).removingPercentEncoding ?? String($0) } ?? ""
            let host = DomainCheck.domain(ofAddress: address).map(Punycode.asciiHost)
            let url = URL(string: "mailto:" + (address.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed.union(["@"])) ?? ""))
            return LinkAssessment(link: link, scheme: scheme, host: host, registrableDomain: host.map(DomainCheck.organisationDomain),
                                  displayDestination: "mailto:" + address, openURL: url, warnings: [])
        }

        guard let parts = URLParts(cleaned) else {
            return LinkAssessment(link: link, scheme: scheme, host: nil, registrableDomain: nil,
                                  displayDestination: String(href.prefix(300)), openURL: nil, warnings: [.blockedScheme(scheme)])
        }
        let asciiHost = Punycode.asciiHost(parts.host)
        // Written as Unicode or as xn--: judge the characters it really has.
        let unicodeHost = Punycode.unicodeHost(asciiHost)
        let registrable = DomainCheck.organisationDomain(of: asciiHost)

        if scheme == "http" { warnings.append(.unencrypted) }
        if parts.hasUserInfo { warnings.append(.userInfoInURL) }
        if Self.isIPAddress(unicodeHost) { warnings.append(.ipAddressHost) }
        if unicodeHost.unicodeScalars.contains(where: { !$0.isASCII }) {
            warnings.append(.internationalizedHost)
            if unicodeHost.split(separator: ".").contains(where: { Self.scripts(in: String($0)).count > 1 }) {
                warnings.append(.mixedScripts)
            }
        }
        if let shown = Self.hostShown(in: link.text) {
            let shownDomain = DomainCheck.organisationDomain(of: Punycode.asciiHost(shown))
            if shownDomain != registrable { warnings.append(.textShowsOtherDomain(shown: shown)) }
        }
        if let sender = senderAddress.flatMap(DomainCheck.domain(ofAddress:)) {
            let senderDomain = DomainCheck.organisationDomain(of: Punycode.asciiHost(sender))
            if let target = DomainCheck.lookalikeTarget(ofHost: asciiHost, trusted: [senderDomain]) {
                warnings.append(.lookalike(of: target))
            }
        }

        var components = URLComponents()
        components.scheme = scheme
        components.percentEncodedHost = asciiHost.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
        components.port = parts.port
        components.percentEncodedPath = Self.encode(parts.path, allowed: .urlPathAllowed)
        components.percentEncodedQuery = parts.query.map { Self.encode($0, allowed: .urlQueryAllowed) }
        components.percentEncodedFragment = parts.fragment.map { Self.encode($0, allowed: .urlFragmentAllowed) }
        let url = components.url
        let display = url?.absoluteString ?? "\(scheme)://\(asciiHost)\(parts.path)"
        return LinkAssessment(link: link, scheme: scheme, host: asciiHost, registrableDomain: registrable,
                              displayDestination: String(display.prefix(2_000)), openURL: url, warnings: warnings)
    }

    // MARK: Helpers

    /// An `http(s)` URL split by hand, so hostile or internationalized input never depends on
    /// what `URL(string:)` accepts.
    struct URLParts {
        var host: String
        var port: Int?
        var path: String
        var query: String?
        var fragment: String?
        var hasUserInfo: Bool

        init?(_ url: String) {
            guard let schemeEnd = url.range(of: "://") else { return nil }
            var rest = url[schemeEnd.upperBound...]
            if let hash = rest.firstIndex(of: "#") { fragment = String(rest[rest.index(after: hash)...]); rest = rest[..<hash] }
            if let question = rest.firstIndex(of: "?") { query = String(rest[rest.index(after: question)...]); rest = rest[..<question] }
            let slash = rest.firstIndex(where: { $0 == "/" || $0 == "\\" }) ?? rest.endIndex
            var authority = String(rest[..<slash])
            path = String(rest[slash...]).replacingOccurrences(of: "\\", with: "/")
            if path.isEmpty { path = "/" }
            hasUserInfo = authority.contains("@")
            if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
            if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
                host = String(authority[...close])
                let after = authority[authority.index(after: close)...]
                if after.hasPrefix(":") { port = Int(after.dropFirst()) }
            } else if let colon = authority.lastIndex(of: ":") {
                host = String(authority[..<colon])
                port = Int(authority[authority.index(after: colon)...])
            } else {
                host = authority
            }
            host = (host.removingPercentEncoding ?? host).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            // Full-width and ideographic dots are label separators too (IDNA).
            for dot in ["\u{3002}", "\u{FF0E}", "\u{FF61}"] { host = host.replacingOccurrences(of: dot, with: ".") }
            guard !host.isEmpty else { return nil }
        }
    }

    static func encode(_ text: String, allowed: CharacterSet) -> String {
        // Keep existing %XX escapes; encode everything else that is not allowed.
        var allowedWithPercent = allowed
        allowedWithPercent.insert("%")
        return text.addingPercentEncoding(withAllowedCharacters: allowedWithPercent) ?? ""
    }

    static func isIPAddress(_ host: String) -> Bool {
        if host.hasPrefix("[") { return true }
        let labels = host.split(separator: ".")
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) { return true }
        // Single-number hosts (http://3232235777/) are IPv4 too.
        return !host.isEmpty && host.allSatisfy { $0.isNumber || $0 == "x" } && host.first?.isNumber == true
    }

    /// A domain the link text shows (`www.example.com`, `https://example.com/login`), if any.
    static func hostShown(in text: String) -> String? {
        let pattern = #"(?i)(?:[a-z][a-z0-9+.-]*://)?(?:[^\s/@]+@)?((?:[\p{L}\p{N}-]+\.)+[\p{L}]{2,})(?=$|[\s/:?#)\],;!>'"])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return text[range].lowercased()
    }

    enum Script: Hashable { case latin, greek, cyrillic, other }

    static func scripts(in label: String) -> Set<Script> {
        var result = Set<Script>()
        for scalar in label.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: result.insert(.latin)
            case 0x370...0x3FF, 0x1F00...0x1FFF: result.insert(.greek)
            case 0x400...0x52F: result.insert(.cyrillic)
            default: result.insert(.other)
            }
        }
        return result
    }
}
