import Foundation
import MailClassifier
import MailCore

// Your classification decisions (GKM-017, MAIL-039): corrections of single messages and the
// scoped rules you chose to make from them. They are user data, not derived data: kept apart from
// the index in `<device folder>/metadata/classification.json`, so a rebuild or a rule-set upgrade
// never touches them, and shaped as records (stable id, account, dates) so GKM-026 can sync them
// through private CloudKit as they are.

/// A correction of one message: its purpose, its risk, or both.
///
/// It finds its message by content fingerprint, the same on every device for the same bytes. A
/// correction that only sets the purpose also follows the Message-ID (a re-download after a
/// parser change); one that lowers the risk ("Not phishing") never does, because anyone can
/// reuse a Message-ID and a phish must not inherit your "Not phishing".
public struct ClassificationCorrection: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var account: MailAccountID
    public var messageID: String?
    public var fingerprint: String
    public var purpose: MailPurpose?
    public var risk: MailRisk?
    public var createdAt: Date
    public var updatedAt: Date

    func matches(account: MailAccountID, messageID: String?, fingerprint: String) -> Bool {
        guard account == self.account else { return false }
        if fingerprint == self.fingerprint { return true }
        let lowersRisk = risk.map { !$0.isQuarantined } ?? false
        guard !lowersRisk, let messageID, let mine = self.messageID else { return false }
        return messageID == mine
    }
}

/// A rule you made from a correction: every message from this sender, or on this list, in one
/// account, gets this purpose. Rules never lower risk (MailClassifier), so a rule for a sender
/// cannot hide a spoof of that sender.
public struct ClassificationRule: Codable, Sendable, Equatable, Identifiable {
    public enum Scope: Codable, Sendable, Equatable, Hashable {
        /// The From address, never the display name.
        case sender(String)
        /// A List-ID, without angle brackets.
        case list(String)
    }

    public var id: String
    public var account: MailAccountID
    public var scope: Scope
    public var purpose: MailPurpose
    public var isEnabled: Bool
    public var createdAt: Date

    var scopedRule: ScopedRule {
        switch scope {
        case .sender(let address): ScopedRule(id: id, scope: .senderAddress(address), purpose: purpose, isEnabled: isEnabled)
        case .list(let list): ScopedRule(id: id, scope: .listID(list), purpose: purpose, isEnabled: isEnabled)
        }
    }
}

/// The file the corrections and rules live in.
struct ClassificationMetadata: Codable, Equatable {
    static let version = 1
    var version = Self.version
    var corrections: [ClassificationCorrection] = []
    var rules: [ClassificationRule] = []

    static func url(in deviceFolder: URL) -> URL {
        deviceFolder.appendingPathComponent("metadata", isDirectory: true).appendingPathComponent("classification.json")
    }

    /// Reads the file; a missing file is empty. A damaged or newer file is an error, never
    /// silently replaced: it holds your decisions.
    static func load(from url: URL) throws -> ClassificationMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else { return ClassificationMetadata() }
        let metadata = try JSONCoding.decoder.decode(ClassificationMetadata.self, from: Data(contentsOf: url))
        guard metadata.version <= Self.version else { throw MailStoreError.unsupportedMetadataVersion(metadata.version) }
        return metadata
    }

    func save(to url: URL, writer: AtomicWriter) throws {
        try writer.write(JSONCoding.prettyEncoder.encode(self), to: url)
    }

    func correction(account: MailAccountID, messageID: String?, fingerprint: String) -> ClassificationCorrection? {
        corrections.last { $0.matches(account: account, messageID: messageID, fingerprint: fingerprint) }
    }

    func scopedRules(account: MailAccountID) -> [ScopedRule] {
        rules.filter { $0.account == account }.map(\.scopedRule)
    }
}
