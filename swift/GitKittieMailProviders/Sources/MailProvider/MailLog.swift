import Foundation

public enum MailLogLevel: Int, Sendable, Comparable, CustomStringConvertible {
    case trace, debug, info, warning, error

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .trace: "trace"
        case .debug: "debug"
        case .info: "info"
        case .warning: "warning"
        case .error: "error"
        }
    }
}

public struct MailLogRecord: Sendable {
    public var level: MailLogLevel
    public var category: String
    public var message: String
    public var date: Date
}

/// Where protocol diagnostics go.
///
/// The adapters never format a credential into a message: commands that carry one (`LOGIN`,
/// `AUTHENTICATE`, SMTP `AUTH`) are logged by name only. As a second line of defence a log can
/// be told which secrets are in play (``scrubbing(_:)``); any record that still contains one of
/// them, or its base64 forms, has it replaced before the sink sees it.
public struct MailLog: Sendable {
    public var minimumLevel: MailLogLevel
    private let sink: @Sendable (MailLogRecord) -> Void
    private let secrets: [String]

    public init(minimumLevel: MailLogLevel = .info, sink: @escaping @Sendable (MailLogRecord) -> Void) {
        self.minimumLevel = minimumLevel
        self.sink = sink
        self.secrets = []
    }

    private init(minimumLevel: MailLogLevel, sink: @escaping @Sendable (MailLogRecord) -> Void, secrets: [String]) {
        self.minimumLevel = minimumLevel
        self.sink = sink
        self.secrets = secrets
    }

    /// A log that drops everything.
    public static let disabled = MailLog(minimumLevel: .error) { _ in }

    /// The same log, also scrubbing these secrets from every record.
    public func scrubbing(_ extra: [Secret]) -> MailLog {
        var forms = secrets
        for secret in extra where !secret.isEmpty {
            secret.withValue { value in
                forms.append(value)
                // How a secret can travel inside SASL: on its own and as part of PLAIN's message.
                forms.append(Data(value.utf8).base64EncodedString())
            }
        }
        return MailLog(minimumLevel: minimumLevel, sink: sink, secrets: forms)
    }

    public func log(_ level: MailLogLevel, _ category: String, _ message: @autoclosure () -> String) {
        guard level >= minimumLevel else { return }
        var text = message()
        for secret in secrets where text.contains(secret) {
            text = text.replacingOccurrences(of: secret, with: Redaction.placeholder)
        }
        sink(MailLogRecord(level: level, category: category, message: text, date: Date()))
    }

    public func trace(_ category: String, _ message: @autoclosure () -> String) { log(.trace, category, message()) }
    public func debug(_ category: String, _ message: @autoclosure () -> String) { log(.debug, category, message()) }
    public func info(_ category: String, _ message: @autoclosure () -> String) { log(.info, category, message()) }
    public func warning(_ category: String, _ message: @autoclosure () -> String) { log(.warning, category, message()) }
    public func error(_ category: String, _ message: @autoclosure () -> String) { log(.error, category, message()) }
}
