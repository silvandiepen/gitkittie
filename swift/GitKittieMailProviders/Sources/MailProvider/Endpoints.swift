import Foundation

/// How the connection to a mail server is protected.
public enum TransportSecurity: Sendable, Hashable, CustomStringConvertible {
    /// TLS from the first byte (IMAP 993, SMTP 465). Preferred (RFC 8314).
    case implicitTLS
    /// Plain greeting, then STARTTLS before anything else (SMTP 587). If the server does not
    /// offer STARTTLS the client stops: it never authenticates or sends mail in the clear.
    case startTLS
    /// No TLS at all. Only for a server on this machine (tests, a local bridge); refused for
    /// any other host.
    case plaintextLoopbackOnly

    public var description: String {
        switch self {
        case .implicitTLS: "implicit TLS"
        case .startTLS: "STARTTLS"
        case .plaintextLoopbackOnly: "plaintext (loopback only)"
        }
    }
}

/// Which certificates a TLS connection accepts.
public enum TrustPolicy: Sendable, Hashable {
    /// The system's trust store, with full chain and host name validation. The only policy
    /// a shipping app uses for a public provider.
    case system
    /// Only these root certificates (PEM). Chain and host name are still validated. For the
    /// local test server, and later for a self-hosted server the user explicitly trusts.
    case customRoots(pem: [Data])
}

public struct ServerEndpoint: Sendable, Hashable, CustomStringConvertible {
    public var host: String
    public var port: Int
    public var security: TransportSecurity
    public var trust: TrustPolicy
    /// How long to wait for the TCP connection and the TLS handshake.
    public var connectTimeout: Duration

    public init(
        host: String,
        port: Int,
        security: TransportSecurity,
        trust: TrustPolicy = .system,
        connectTimeout: Duration = .seconds(20)
    ) {
        self.host = host
        self.port = port
        self.security = security
        self.trust = trust
        self.connectTimeout = connectTimeout
    }

    public var isLoopback: Bool {
        ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
    }

    public var description: String { "\(host):\(port) (\(security))" }
}

extension ServerEndpoint {
    /// iCloud Mail, per https://support.apple.com/en-us/102525: IMAP on 993 with TLS, SMTP on
    /// 587 with STARTTLS. Sign in with the full address and an app-specific password.
    public static let iCloudIMAP = ServerEndpoint(host: "imap.mail.me.com", port: 993, security: .implicitTLS)
    public static let iCloudSMTP = ServerEndpoint(host: "smtp.mail.me.com", port: 587, security: .startTLS)
}
