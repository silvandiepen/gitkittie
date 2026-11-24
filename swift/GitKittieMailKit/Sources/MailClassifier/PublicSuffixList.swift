import Foundation

/// The Public Suffix List (https://publicsuffix.org), bundled as `Resources/public_suffix_list.dat`
/// (MPL-2.0, unmodified; the version line at its top says which). It answers "which part of a host
/// is the organisation": `shop.example.co.uk` belongs to `example.co.uk`, `a.github.io` is its own.
///
/// Both the ICANN and the private sections count, so a user site on a shared host is not the
/// host's organisation. The reserved documentation domains `example.com`, `example.net` and
/// `example.org` (RFC 2606) are treated as public suffixes too: no real organisation sends from
/// them, and the synthetic fixtures use their subdomains as separate organisations.
///
/// Matching follows the list's algorithm: the longest matching rule wins, an exception rule
/// (`!`) beats a wildcard (`*.`), and an unlisted top-level domain is a suffix of one label.
/// Rules and hosts are compared in their ASCII (`xn--`) form.
public struct PublicSuffixList: Sendable {
    private let rules: Set<String>
    private let wildcards: Set<String>
    private let exceptions: Set<String>
    /// The `VERSION:` line of the bundled file.
    public let version: String

    /// Reserved documentation domains, handled as suffixes (see above).
    static let reservedSuffixes = ["example.com", "example.net", "example.org"]

    /// The bundled list, parsed once.
    public static let shared: PublicSuffixList = {
        guard let url = Bundle.module.url(forResource: "public_suffix_list", withExtension: "dat"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            // The list is a resource of this target; without it the build is broken, not the input.
            preconditionFailure("public_suffix_list.dat is missing from the MailClassifier bundle")
        }
        return PublicSuffixList(text: text)
    }()

    public init(text: String) {
        var rules = Set(Self.reservedSuffixes)
        var wildcards = Set<String>()
        var exceptions = Set<String>()
        var version = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("// VERSION:") { version = line.dropFirst("// VERSION:".count).trimmingCharacters(in: .whitespaces) }
            guard !line.isEmpty, !line.hasPrefix("//") else { continue }
            // A rule is the first whitespace-free run on its line.
            let rule = String(line.split(separator: " ").first ?? "")
            if rule.hasPrefix("!") {
                exceptions.insert(Self.ascii(rule.dropFirst()))
            } else if rule.hasPrefix("*.") {
                wildcards.insert(Self.ascii(rule.dropFirst(2)))
            } else {
                rules.insert(Self.ascii(Substring(rule)))
            }
        }
        self.rules = rules
        self.wildcards = wildcards
        self.exceptions = exceptions
        self.version = version
    }

    /// The public suffix of `host` (`co.uk` for `shop.example.co.uk`).
    public func publicSuffix(of host: String) -> String {
        let labels = Self.labels(host)
        guard !labels.isEmpty else { return "" }
        for start in labels.indices {
            let candidate = labels[start...].joined(separator: ".")
            if exceptions.contains(candidate) { return labels[(start + 1)...].joined(separator: ".") }
            if rules.contains(candidate) { return candidate }
            if start + 1 < labels.count, wildcards.contains(labels[(start + 1)...].joined(separator: ".")) { return candidate }
        }
        return labels[labels.count - 1]
    }

    /// The registrable domain: the public suffix plus one label (`example.co.uk`). A host that
    /// is itself a public suffix (or empty) is returned as given, lowercased.
    public func registrableDomain(of host: String) -> String {
        let labels = Self.labels(host)
        let suffix = publicSuffix(of: host)
        let suffixCount = suffix.isEmpty ? 0 : suffix.split(separator: ".").count
        guard labels.count > suffixCount else { return labels.joined(separator: ".") }
        return labels.suffix(suffixCount + 1).joined(separator: ".")
    }

    /// Most rules are ASCII already; only the others need encoding.
    private static func ascii(_ rule: Substring) -> String {
        rule.utf8.allSatisfy { $0 < 0x80 } ? rule.lowercased() : Punycode.asciiHost(String(rule))
    }

    static func labels(_ host: String) -> [String] {
        Punycode.asciiHost(host.trimmingCharacters(in: CharacterSet(charactersIn: ". ")))
            .split(separator: ".", omittingEmptySubsequences: true).map(String.init)
    }
}
