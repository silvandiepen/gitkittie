import Foundation

/// Organisation domains and lookalikes.
///
/// PROVISIONAL: the organisation domain should come from the Public Suffix List. Until a PSL
/// is bundled this keeps the last two labels, and treats the reserved `example.com/.org/.net`
/// domains as public suffixes, so synthetic senders such as `shop.example.com` behave like
/// separate organisations in the fixtures.
enum DomainHeuristics {
    private static let reservedSuffixes = ["example.com", "example.org", "example.net"]

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
        let labels = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if reservedSuffixes.contains(lastTwo) { return labels.suffix(3).joined(separator: ".") }
        return lastTwo
    }

    /// The distinctive label of an organisation domain: `cloudvault` in `cloudvault.example.com`.
    static func organisationLabel(_ organisation: String) -> String {
        String(organisation.split(separator: ".").first ?? "")
    }

    /// The trusted organisation `organisation` imitates, if any. An exact match is not a lookalike.
    static func lookalikeTarget(of organisation: String, trusted: Set<String>) -> String? {
        guard !trusted.contains(organisation) else { return nil }
        let label = organisationLabel(organisation)
        for target in trusted.sorted() {
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
