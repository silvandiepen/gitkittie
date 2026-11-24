import Foundation
import MailCore
import MailIMAP
import MailProvider
import MailSMTP

/// Turns an account's recorded settings and its Keychain password into live connections.
/// One place decides how the app connects, so verification and sync use exactly the same
/// servers, security and trust.
public struct AccountConnections: Sendable {
    /// Which certificates are accepted. `.system` for every real provider; custom roots only
    /// for the local test server (and, later, a self-hosted server the person trusts).
    public var trust: TrustPolicy
    public var log: MailLog
    public var connectTimeout: Duration
    public var commandTimeout: Duration

    public init(trust: TrustPolicy = .system, log: MailLog = .disabled,
                connectTimeout: Duration = .seconds(20), commandTimeout: Duration = .seconds(60)) {
        self.trust = trust
        self.log = log
        self.connectTimeout = connectTimeout
        self.commandTimeout = commandTimeout
    }

    public func endpoint(_ server: MailServerSettings) -> ServerEndpoint {
        let security: TransportSecurity = switch server.security {
        case .implicitTLS: .implicitTLS
        case .startTLS: .startTLS
        }
        return ServerEndpoint(host: server.host.trimmingCharacters(in: .whitespacesAndNewlines), port: server.port,
                              security: security, trust: trust, connectTimeout: connectTimeout)
    }

    public func imap(_ connection: MailConnectionSettings, password: Secret) -> IMAPConnector {
        IMAPConnector(endpoint: endpoint(connection.imap),
                      credential: .password(username: connection.imap.username, password: password),
                      log: log, commandTimeout: commandTimeout)
    }

    public func smtp(_ connection: MailConnectionSettings, password: Secret) -> SMTPSubmitter {
        SMTPSubmitter(endpoint: endpoint(connection.smtp),
                      credential: .password(username: connection.smtp.username, password: password),
                      log: log, replyTimeout: commandTimeout)
    }
}
