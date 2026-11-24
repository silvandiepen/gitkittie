import Foundation
import MailNet
import MailProvider
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL

/// Opens authenticated IMAP sessions to one account.
///
/// Only implicit TLS (993) is supported for IMAP: every provider in scope offers it and RFC 8314
/// prefers it. `.plaintextLoopbackOnly` exists for a server on this machine.
public struct IMAPConnector: MailboxConnector {
    public var endpoint: ServerEndpoint
    public var credential: MailCredential
    public var log: MailLog
    public var commandTimeout: Duration

    public init(endpoint: ServerEndpoint, credential: MailCredential, log: MailLog = .disabled,
                commandTimeout: Duration = .seconds(60)) {
        self.endpoint = endpoint
        self.credential = credential
        self.log = log.scrubbing([credential.secret])
        self.commandTimeout = commandTimeout
    }

    public func withSession<Result>(_ body: (any MailboxSession) async throws -> Result) async throws -> Result {
        try await withIMAPSession { try await body($0) }
    }

    /// The same as ``withSession(_:)`` with the concrete type, for IMAP-only details.
    public func withIMAPSession<Result>(_ body: (IMAPSession) async throws -> Result) async throws -> Result {
        let endpoint = self.endpoint
        switch endpoint.security {
        case .implicitTLS: break
        case .plaintextLoopbackOnly: try MailNet.checkPlaintextAllowed(endpoint)
        case .startTLS: throw MailProviderError.unsupported("IMAP STARTTLS; use implicit TLS on port 993")
        }
        log.info("imap", "connecting to \(endpoint)")

        let tlsHandlerFactory: (@Sendable () throws -> NIOSSLClientHandler)?
        if endpoint.security == .implicitTLS {
            let context = try MailNet.makeTLSContext(endpoint.trust)
            tlsHandlerFactory = { try NIOSSLClientHandler(context: context, serverHostname: endpoint.host) }
        } else {
            tlsHandlerFactory = nil
        }

        let asyncChannel: NIOAsyncChannel<Response, IMAPClientHandler.Message>
        do {
            asyncChannel = try await MailNet.makeBootstrap(for: endpoint).connect(
                host: endpoint.host, port: endpoint.port
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let tlsHandlerFactory {
                        try channel.pipeline.syncOperations.addHandler(tlsHandlerFactory())
                    }
                    try channel.pipeline.syncOperations.addHandler(IMAPClientHandler())
                    return try NIOAsyncChannel<Response, IMAPClientHandler.Message>(wrappingChannelSynchronously: channel)
                }
            }
        } catch {
            throw MailProviderError.connectionFailed(MailNet.describe(error))
        }

        let log = self.log
        let credential = self.credential
        let commandTimeout = self.commandTimeout
        return try await asyncChannel.executeThenClose { inbound, outbound in
            let wire = IMAPWire(inbound: inbound, outbound: outbound, channel: asyncChannel.channel,
                                log: log, commandTimeout: commandTimeout)
            do {
                // The TLS handshake runs as part of reading the greeting; a bad certificate
                // fails here.
                _ = try await wire.readGreeting()
            } catch let error as MailProviderError {
                if case .connectionLost(let reason) = error { throw MailProviderError.connectionFailed(reason) }
                throw error
            }
            let session = try await IMAPSession.open(wire: wire, credential: credential, log: log)
            do {
                let result = try await body(session)
                await session.close()
                return result
            } catch {
                await session.close()
                throw error
            }
        }
    }
}
