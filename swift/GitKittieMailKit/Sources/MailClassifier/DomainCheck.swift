import Foundation

/// The classifier's domain heuristics for the reader's link and sender warnings (GKM-012), so
/// both use one definition of "organisation domain" (the Public Suffix List) and "lookalike".
public enum DomainCheck {
    /// The domain of an address, lowercased (`shop.example.com` for `a@shop.example.com`).
    public static func domain(ofAddress address: String) -> String? {
        DomainHeuristics.domain(of: address)
    }

    /// The registrable part of a host, the part people should read (`cloudvault.example.com`
    /// for `login.cloudvault.example.com`).
    public static func organisationDomain(of host: String) -> String {
        DomainHeuristics.organisationDomain(host)
    }

    /// The trusted organisation `host` imitates (`c1oudvault…` for `cloudvault…`), if any.
    /// Exactly the same organisation is not a lookalike.
    public static func lookalikeTarget(ofHost host: String, trusted: Set<String>) -> String? {
        DomainHeuristics.lookalikeTarget(of: DomainHeuristics.organisationDomain(host), trusted: trusted)
    }

    /// True for a host that is itself a public suffix (`co.uk`): no organisation owns it.
    public static func isPublicSuffix(_ host: String) -> Bool {
        DomainHeuristics.isPublicSuffix(host)
    }
}
