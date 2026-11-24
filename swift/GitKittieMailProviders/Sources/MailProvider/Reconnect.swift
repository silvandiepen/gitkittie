import Foundation

/// Exponential backoff with jitter for reconnecting after a network failure
/// (Architecture.md, Multi-device sync: reconnect/backoff).
public struct ReconnectPolicy: Sendable, Hashable {
    public var maxAttempts: Int
    public var initialDelay: Duration
    public var maxDelay: Duration
    /// 0 = no jitter, 0.5 = up to 50% shorter.
    public var jitter: Double

    public init(maxAttempts: Int = 6, initialDelay: Duration = .milliseconds(500),
                maxDelay: Duration = .seconds(60), jitter: Double = 0.3) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    /// The delay before attempt `attempt` (1 = the first retry), with `random` in 0..<1.
    public func delay(beforeRetry attempt: Int, random: Double) -> Duration {
        let exponent = max(0, attempt - 1)
        let base = initialDelay * Int(pow(2.0, Double(min(exponent, 20))))
        let capped = min(base, maxDelay)
        let factor = 1.0 - jitter * min(max(random, 0), 1)
        return capped * factor
    }

    /// Runs `body` in a fresh session, and again in a new session after a connection problem,
    /// up to `maxAttempts` times. `body` must be safe to repeat (fetches, flag sets, searches);
    /// sending mail is not, and goes through the outbox instead.
    public func run<Result>(
        _ connector: some MailboxConnector,
        log: MailLog = .disabled,
        _ body: (any MailboxSession) async throws -> Result
    ) async throws -> Result {
        try await retrying(log: log) { try await connector.withSession(body) }
    }

    /// Runs `operation` until it succeeds, fails with something other than a connection
    /// problem, or has failed `maxAttempts` times.
    public func retrying<Result>(
        log: MailLog = .disabled,
        _ operation: () async throws -> Result
    ) async throws -> Result {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await operation()
            } catch let error as MailProviderError where error.isConnectionProblem && attempt < maxAttempts {
                let wait = delay(beforeRetry: attempt, random: Double.random(in: 0..<1))
                log.warning("reconnect", "attempt \(attempt) failed (\(error)); retrying in \(wait)")
                try await Task.sleep(for: wait)
            }
        }
    }
}
