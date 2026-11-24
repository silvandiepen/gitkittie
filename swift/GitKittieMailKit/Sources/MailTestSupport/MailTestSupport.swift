import Foundation
import MailCore

/// The synthetic fixture corpus (GKM-003). Never real mail, never a real address.
public enum MailFixtures {
    /// The folder the fixtures are copied to in the test bundle.
    public static var directory: URL? { Bundle.module.url(forResource: "Fixtures", withExtension: nil) }

    /// Every `.eml` file in the corpus, sorted by name.
    public static func messageURLs() throws -> [URL] {
        guard let directory else { throw FixtureError.missingDirectory }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "eml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The expected labels and parse outcome for every fixture.
    public static func expectations() throws -> FixtureExpectations {
        guard let url = directory?.appendingPathComponent("expectations.json") else { throw FixtureError.missingDirectory }
        return try JSONDecoder().decode(FixtureExpectations.self, from: Data(contentsOf: url))
    }

    public enum FixtureError: Error { case missingDirectory }
}

/// `Fixtures/expectations.json`.
public struct FixtureExpectations: Codable, Sendable {
    public var version: Int
    public var note: String
    public var context: Context
    public var fixtures: [Fixture]

    /// The mailbox the corpus is addressed to, and what that mailbox already knows. Real
    /// values come from the account and its history; these are fixed for repeatable tests.
    public struct Context: Codable, Sendable {
        public var accountAddresses: [String]
        /// `authserv-id`s whose Authentication-Results are trusted (the account's own provider).
        public var trustedAuthServIDs: [String]
        /// Addresses the user has written to.
        public var knownCorrespondents: [String]
        /// Organisations the user has an established, authenticated relationship with.
        public var trustedSenderDomains: [String]
    }

    public struct Fixture: Codable, Sendable {
        public var file: String
        public var description: String
        /// BCP 47 language of the human-readable content.
        public var language: String
        public var purpose: MailPurpose
        public var risk: MailRisk
        public var urgency: MailUrgency
        public var parse: ParseExpectation
        /// The provider's own junk verdict, when the fixture models one ("spam", "phishing", "notSpam").
        public var providerVerdict: String?
        /// Fixtures that share a Message-ID on purpose name the same group.
        public var duplicateGroup: String?
        public var tags: [String]
    }

    public struct ParseExpectation: Codable, Sendable {
        public var outcome: ParseOutcome
        public var warnings: [ParseWarning]
    }
}
