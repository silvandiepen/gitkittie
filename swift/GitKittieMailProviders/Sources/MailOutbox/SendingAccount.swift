import Foundation
import MailCore
import MailIMAP
import MailProvider
import MailSMTP

/// Where an account's password or token lives in the Keychain. Only the reference is ever
/// stored or passed around; the secret is read at the moment of connecting.
public struct CredentialReference: Codable, Sendable, Hashable {
    /// The Keychain item's service.
    public var service: String
    /// The Keychain item's account (GKM-010 keys items by the local account id).
    public var account: String
    /// The name to sign in with (for iCloud and most providers, the full address).
    public var username: String

    public init(service: String, account: String, username: String) {
        self.service = service
        self.account = account
        self.username = username
    }
}

/// Turns a ``CredentialReference`` into a credential, at the moment it is needed. The app
/// implements it on the Keychain (GKM-010).
public protocol CredentialProvider: Sendable {
    func credential(for reference: CredentialReference) async throws -> MailCredential
}

/// How a provider keeps a copy of what was sent (Architecture.md, Sending and drafts:
/// provider-specific Sent copy behaviour avoids duplicates).
public enum SentCopyPolicy: String, Codable, Sendable, Hashable {
    /// The provider files every SMTP submission in Sent itself (Gmail). Appending would make
    /// a second copy, so the outbox never does.
    case providerFiles
    /// The provider keeps nothing (most IMAP hosts). The outbox appends one copy to Sent,
    /// after checking by Message-ID that none is there yet.
    case append
    /// Not known yet for this provider (iCloud until the GKM-004 run says). The outbox waits
    /// ``Outbox/Configuration/sentCopyDetectionWindow`` for the provider's own copy and appends
    /// only if none appears.
    case detect
    /// Keep no copy.
    case none
}

/// An account you can send from: the identity, the SMTP endpoint, where its credential is, and
/// what its provider does with sent mail. GKM-010's account model implements this; the outbox
/// needs nothing else from it.
public protocol SendingAccount: Sendable {
    var accountID: MailAccountID { get }
    /// The addresses this account may send as. The first is the default identity.
    var identities: [MailAddress] { get }
    var smtp: ServerEndpoint { get }
    /// For reconciliation and the Sent copy. Without one, an uncertain send stays uncertain
    /// until the person decides.
    var imap: ServerEndpoint? { get }
    var credential: CredentialReference { get }
    var sentCopy: SentCopyPolicy { get }
    /// The Sent folder's provider name, when known. Otherwise the folder with the Sent role.
    var sentFolder: String? { get }
}

/// The plain value form of ``SendingAccount``, built from MailStore's `MailAccount` plus the
/// server settings account setup collects.
public struct SendingAccountSettings: SendingAccount, Hashable {
    public var accountID: MailAccountID
    public var identities: [MailAddress]
    public var smtp: ServerEndpoint
    public var imap: ServerEndpoint?
    public var credential: CredentialReference
    public var sentCopy: SentCopyPolicy
    public var sentFolder: String?

    public init(accountID: MailAccountID, identities: [MailAddress], smtp: ServerEndpoint, imap: ServerEndpoint?,
                credential: CredentialReference, sentCopy: SentCopyPolicy, sentFolder: String? = nil) {
        self.accountID = accountID
        self.identities = identities
        self.smtp = smtp
        self.imap = imap
        self.credential = credential
        self.sentCopy = sentCopy
        self.sentFolder = sentFolder
    }

    /// The account as the mail folder records it, with its address as the identity and any
    /// aliases after it.
    public init(account: MailAccount, aliases: [MailAddress] = [], smtp: ServerEndpoint, imap: ServerEndpoint?,
                credential: CredentialReference, sentCopy: SentCopyPolicy, sentFolder: String? = nil) {
        let main = MailAddress(name: account.displayName.isEmpty ? nil : account.displayName, address: account.address)
        self.init(accountID: account.id, identities: [main] + aliases, smtp: smtp, imap: imap,
                  credential: credential, sentCopy: sentCopy, sentFolder: sentFolder)
    }

    /// iCloud Mail (https://support.apple.com/en-us/102525). Whether iCloud files SMTP
    /// submissions in Sent itself is what the GKM-004 run records; until then, detect.
    public static func iCloud(account: MailAccount, credential: CredentialReference) -> SendingAccountSettings {
        SendingAccountSettings(account: account, smtp: .iCloudSMTP, imap: .iCloudIMAP, credential: credential,
                               sentCopy: .detect, sentFolder: "Sent Messages")
    }
}

/// Finds the sending settings for an account at the moment of sending, so a queued message
/// uses the current endpoint and credential while its identity and recipients stay as they
/// were when Send was pressed.
public protocol SendingAccountDirectory: Sendable {
    func sendingAccount(_ id: MailAccountID) async throws -> (any SendingAccount)?
}

/// Opens the connections the outbox needs for one account.
public protocol OutboxTransport: Sendable {
    func submitter(for account: any SendingAccount) async throws -> any MailSubmitter
    /// Nil when the account has no mailbox access configured.
    func mailbox(for account: any SendingAccount) async throws -> (any MailboxConnector)?
}

/// The real connections: ``SMTPSubmitter`` and ``IMAPConnector`` with the account's
/// credential, read from the ``CredentialProvider`` for each connection.
public struct NetworkOutboxTransport: OutboxTransport {
    public var credentials: any CredentialProvider
    public var log: MailLog

    public init(credentials: any CredentialProvider, log: MailLog = .disabled) {
        self.credentials = credentials
        self.log = log
    }

    public func submitter(for account: any SendingAccount) async throws -> any MailSubmitter {
        SMTPSubmitter(endpoint: account.smtp, credential: try await credentials.credential(for: account.credential), log: log)
    }

    public func mailbox(for account: any SendingAccount) async throws -> (any MailboxConnector)? {
        guard let imap = account.imap else { return nil }
        return IMAPConnector(endpoint: imap, credential: try await credentials.credential(for: account.credential), log: log)
    }
}
