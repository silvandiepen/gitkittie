import Foundation

/// A password, app-specific password or access token.
///
/// Its value never shows up in `print`, string interpolation, `dump` or a debugger summary: all
/// of them print `‹redacted›`. Code that has to put the value on the wire asks for it explicitly
/// with ``withValue(_:)``, so every use is greppable. It is deliberately not `Codable`: secrets
/// live in the Keychain, never in a file (Architecture.md, Security and privacy).
public struct Secret: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String

    public init(_ value: String) { self.value = value }

    /// Hands the plain value to `body`. Use it only to write the secret to an authenticated,
    /// encrypted connection; never to log or store it.
    public func withValue<Result>(_ body: (String) throws -> Result) rethrows -> Result {
        try body(value)
    }

    public var isEmpty: Bool { value.isEmpty }

    public var description: String { Redaction.placeholder }
    public var debugDescription: String { Redaction.placeholder }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// How a client proves who it is to a mail server.
public enum MailCredential: Sendable, CustomStringConvertible {
    /// A user name and a password. For iCloud this must be an app-specific password.
    case password(username: String, password: Secret)
    /// A user name and an OAuth 2 access token, for SASL XOAUTH2 (Gmail, Microsoft; GKM-008).
    case oauth2(username: String, accessToken: Secret)

    public var username: String {
        switch self {
        case .password(let username, _), .oauth2(let username, _): username
        }
    }

    /// The secret part, for log scrubbing.
    public var secret: Secret {
        switch self {
        case .password(_, let secret), .oauth2(_, let secret): secret
        }
    }

    public var description: String {
        switch self {
        case .password(let username, _): "password(\(username), \(Redaction.placeholder))"
        case .oauth2(let username, _): "oauth2(\(username), \(Redaction.placeholder))"
        }
    }
}

public enum Redaction {
    public static let placeholder = "‹redacted›"
}
