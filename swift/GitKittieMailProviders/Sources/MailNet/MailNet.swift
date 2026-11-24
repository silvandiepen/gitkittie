import Foundation
import MailProvider
import NIOCore
import NIOPosix
import NIOSSL

// Transport shared by the IMAP and SMTP adapters: one event loop group, one TLS setup.
//
// TLS is swift-nio-ssl. With `TrustPolicy.system` it validates the chain through the Security
// framework (SecTrust), so it trusts exactly what the OS trusts; custom roots are only for a
// local test server or a server the user explicitly trusts. Network.framework
// (swift-nio-transport-services) cannot add TLS to a connection that is already open, which
// SMTP STARTTLS needs, so both protocols use the same stack (MAIL-017).

public enum MailNet {
    /// A small group shared by every mail connection in the process.
    public static let eventLoopGroup: MultiThreadedEventLoopGroup = .singleton

    /// TLS 1.2 or newer, full certificate and host name verification.
    public static func makeTLSContext(_ trust: TrustPolicy) throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv12
        configuration.certificateVerification = .fullVerification
        // Closing waits at most a second for the server's close_notify (default 5 s). Every
        // exchange is complete by then (LOGOUT, QUIT, or a sync that was stopped), and stopping
        // a sync or quitting the app must not hang on a server that never answers it.
        configuration.shutdownTimeout = .seconds(1)
        switch trust {
        case .system:
            configuration.trustRoots = .default
        case .customRoots(let pems):
            var certificates: [NIOSSLCertificate] = []
            for pem in pems {
                certificates += try NIOSSLCertificate.fromPEMBytes(Array(pem))
            }
            guard !certificates.isEmpty else {
                throw MailProviderError.connectionFailed("no certificates in the custom trust roots")
            }
            configuration.trustRoots = .certificates(certificates)
        }
        return try NIOSSLContext(configuration: configuration)
    }

    public static func makeTLSHandler(for endpoint: ServerEndpoint) throws -> NIOSSLClientHandler {
        try NIOSSLClientHandler(context: makeTLSContext(endpoint.trust), serverHostname: endpoint.host)
    }

    /// Refuses plaintext to anything but this machine.
    public static func checkPlaintextAllowed(_ endpoint: ServerEndpoint) throws {
        if endpoint.security == .plaintextLoopbackOnly && !endpoint.isLoopback {
            throw MailProviderError.unsupported("plaintext connections are only allowed to this machine, not \(endpoint.host)")
        }
    }

    public static func makeBootstrap(for endpoint: ServerEndpoint) -> ClientBootstrap {
        ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(TimeAmount.nanoseconds(Int64(endpoint.connectTimeout.components.seconds) * 1_000_000_000
                + endpoint.connectTimeout.components.attoseconds / 1_000_000_000))
            .channelOption(.socketOption(.so_keepalive), value: 1)
    }

    /// Maps transport errors (connect, TLS) onto ``MailProviderError``, never including bytes
    /// that came off the wire.
    public static func describe(_ error: any Error) -> String {
        switch error {
        case let error as NIOSSLError: "TLS: \(error)"
        case let error as NIOSSLExtraError: "TLS: \(error)"
        case let error as BoringSSLError: "TLS: \(error)"
        case let error as ChannelError: "\(error)"
        case let error as IOError: "\(error)"
        case let error as NIOConnectionError: "could not connect (\(error.dnsAError.map { "\($0)" } ?? error.connectionErrors.map { "\($0.error)" }.joined(separator: ", ")))"
        default: "\(error)"
        }
    }

    /// Runs `operation`, failing with `.timedOut` after `timeout`.
    public static func withTimeout<Result: Sendable>(
        _ timeout: Duration,
        _ what: String,
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MailProviderError.timedOut(what)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
