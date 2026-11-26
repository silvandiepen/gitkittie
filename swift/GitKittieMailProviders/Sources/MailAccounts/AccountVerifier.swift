import Foundation
import MailCore
import MailProvider

/// Which of an account's two servers a problem is with.
public enum MailServerRole: String, Sendable, Hashable {
    case incoming
    case outgoing

    var name: String { self == .incoming ? "incoming mail server" : "outgoing mail server" }
}

/// Why an account could not be added, in words a person can act on (GKM-010). A wrong
/// password, an unreachable server and a certificate problem are different messages: each
/// needs a different fix.
public enum AccountSetupError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingField(String)
    case invalidAddress
    /// The provider only allows OAuth sign-in, which comes later (GKM-030).
    case oauthOnly(domain: String)
    case alreadyAdded(address: String)
    case wrongPassword(MailServerRole, host: String, kind: MailAccountKind)
    case unreachable(MailServerRole, host: String, port: Int, detail: String)
    case certificateProblem(MailServerRole, host: String, detail: String)
    /// The server offered no encryption on that port, or no way to sign in with a password.
    case notSecure(MailServerRole, host: String, detail: String)
    case timedOut(MailServerRole, host: String)
    case refused(MailServerRole, host: String, detail: String)
    case keychain(String)
    /// The person cancelled setup; nothing was saved.
    case cancelled

    public var description: String { message }

    /// The message for the setup sheet. Plain, and says what to do next.
    public var message: String {
        switch self {
        case .missingField(let field):
            "Enter the \(field)."
        case .invalidAddress:
            "That doesn’t look like an email address."
        case .oauthOnly(let domain):
            "\(domain) accounts need a Microsoft sign-in, which GitKittie Mail doesn’t support yet. Passwords no longer work for them."
        case .alreadyAdded(let address):
            "\(address) is already added."
        case .wrongPassword(let role, let host, let kind):
            switch kind {
            case .iCloud:
                "iCloud didn’t accept the password. Use an app-specific password from account.apple.com, not your Apple Account password. Changing your Apple Account password revokes the old app-specific passwords."
            case .gmail:
                "Gmail didn’t accept the password. Use an app password (it needs 2-Step Verification), not your Google password."
            case .imap:
                "The \(role.name) (\(host)) didn’t accept the user name or password. If your provider uses app passwords, use one here."
            }
        case .unreachable(let role, let host, let port, _):
            "Couldn’t reach the \(role.name), \(host) on port \(port). Check the server name and port, and that this Mac is online."
        case .certificateProblem(let role, let host, _):
            "The \(role.name) (\(host)) presented a certificate this Mac doesn’t trust, so GitKittie Mail stopped before sending your password. Check the server name; if it is right, ask your provider about their certificate."
        case .notSecure(let role, let host, let detail):
            "The \(role.name) (\(host)) didn’t offer a secure connection with a password sign-in on this port, so nothing was sent. Try the provider’s TLS port (993 for incoming, 465 or 587 for outgoing). \(detail)"
        case .timedOut(let role, let host):
            "The \(role.name) (\(host)) stopped answering. Try again in a moment."
        case .refused(let role, let host, let detail):
            "The \(role.name) (\(host)) refused the connection: \(detail)"
        case .keychain(let detail):
            detail
        case .cancelled:
            "Cancelled. Nothing was saved."
        }
    }

    /// Maps a provider failure on one server onto what the person sees.
    public static func from(_ error: any Error, role: MailServerRole, server: MailServerSettings,
                            kind: MailAccountKind) -> AccountSetupError {
        if error is CancellationError || Task.isCancelled { return .cancelled }
        guard let error = error as? MailProviderError else {
            return .refused(role, host: server.host, detail: String(describing: error))
        }
        switch error {
        case .authenticationFailed:
            return .wrongPassword(role, host: server.host, kind: kind)
        case .connectionFailed(let detail) where error.isTLSFailure:
            return .certificateProblem(role, host: server.host, detail: detail)
        case .connectionFailed(let detail), .connectionLost(let detail):
            return .unreachable(role, host: server.host, port: server.port, detail: detail)
        case .timedOut:
            return .timedOut(role, host: server.host)
        case .unsupported(let detail):
            return .notSecure(role, host: server.host, detail: detail)
        case .commandFailed(let detail), .protocolViolation(let detail), .folderNotFound(let detail), .invalidName(let detail):
            return .refused(role, host: server.host, detail: detail)
        case .messageNotFound(let id):
            return .refused(role, host: server.host, detail: id.description)
        }
    }
}

/// Checks an account's settings and password against both servers before anything is saved
/// (GKM-010): signs in to IMAP and lists the folders, then signs in to SMTP without sending.
public struct AccountVerifier: Sendable {
    public var connections: AccountConnections

    /// Short timeouts: setup must answer, not hang.
    public init(connections: AccountConnections = AccountConnections(connectTimeout: .seconds(15), commandTimeout: .seconds(20))) {
        self.connections = connections
    }

    /// Returns the settings that worked: for iCloud, the IMAP user name the server accepted.
    public func verify(_ connection: MailConnectionSettings, password: Secret) async throws(AccountSetupError) -> MailConnectionSettings {
        var verified = connection
        let usernames = connection.kind == .iCloud
            ? ProviderPresets.iCloudIMAPUsernames(for: connection.imap.username)
            : [connection.imap.username]
        var lastFailure: AccountSetupError?
        var signedIn = false
        for username in usernames {
            var attempt = connection
            attempt.imap.username = username
            do {
                _ = try await connections.imap(attempt, password: password).withSession { session in
                    try await session.listFolders()
                }
                verified.imap.username = username
                signedIn = true
                break
            } catch {
                let failure = AccountSetupError.from(error, role: .incoming, server: attempt.imap, kind: connection.kind)
                lastFailure = failure
                // Only a refused sign-in is worth another user name.
                guard case .wrongPassword = failure else { throw failure }
            }
        }
        guard signedIn else { throw lastFailure ?? .wrongPassword(.incoming, host: connection.imap.host, kind: connection.kind) }

        do {
            try await connections.smtp(verified, password: password).verifySignIn()
        } catch {
            throw AccountSetupError.from(error, role: .outgoing, server: verified.smtp, kind: connection.kind)
        }
        return verified
    }
}
