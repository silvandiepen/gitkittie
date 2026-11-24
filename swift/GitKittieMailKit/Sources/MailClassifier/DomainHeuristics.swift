import Foundation

/// Organisation domains and lookalikes. The organisation domain is the registrable domain from
/// the bundled Public Suffix List (`PublicSuffixList`), so `login.bank.example.co.uk` belongs to
/// `bank.example.co.uk`'s organisation and a user site on a shared host is its own.
enum DomainHeuristics {
    static func domain(of address: String) -> String? {
        guard let at = address.lastIndex(of: "@") else { return nil }
        let domain = address[address.index(after: at)...].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". >"))
        return domain.isEmpty ? nil : domain
    }

    static func localPart(of address: String) -> String {
        guard let at = address.lastIndex(of: "@") else { return address.lowercased() }
        return address[..<at].lowercased()
    }

    static func organisationDomain(_ host: String) -> String {
        PublicSuffixList.shared.registrableDomain(of: host)
    }

    static func isPublicSuffix(_ domain: String) -> Bool {
        PublicSuffixList.shared.publicSuffix(of: domain) == PublicSuffixList.labels(domain).joined(separator: ".")
    }

    /// The distinctive label of an organisation domain: `cloudvault` in `cloudvault.example.com`.
    static func organisationLabel(_ organisation: String) -> String {
        String(organisation.split(separator: ".").first ?? "")
    }

    /// The trusted organisation `organisation` imitates, if any. An exact match is not a lookalike.
    /// A bare public suffix (`co.uk`, or an address directly at a reserved `example.org`) is
    /// nobody's organisation: it is never a lookalike, nor something to imitate.
    static func lookalikeTarget(of organisation: String, trusted: Set<String>) -> String? {
        guard !trusted.contains(organisation), !isPublicSuffix(organisation) else { return nil }
        let label = organisationLabel(organisation)
        for target in trusted.sorted() where !isPublicSuffix(target) {
            let targetLabel = organisationLabel(target)
            guard targetLabel.count >= 4 else { continue }
            if label == targetLabel { return target }                                   // same name, other suffix
            if normalised(label) == normalised(targetLabel) { return target }           // c1oudvault, rn for m
            if label.count >= 5 && editDistance(label, targetLabel) <= 1 { return target }
            if targetLabel.count >= 5 && label.contains(targetLabel) { return target }  // nordbank-kundenservice
        }
        return nil
    }

    /// Folds characters attackers swap for lookalikes.
    static func normalised(_ label: String) -> String {
        var s = label.lowercased()
        for (from, to) in [("rn", "m"), ("vv", "w"), ("0", "o"), ("1", "l"), ("3", "e"), ("5", "s"), ("-", "")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        return s
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
