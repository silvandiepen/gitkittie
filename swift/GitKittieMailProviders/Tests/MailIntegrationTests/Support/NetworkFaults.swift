import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL

// Real network conditions in front of the real test server: a TCP proxy that can cut every
// connection on demand, or cut an SMTP connection right after the server accepted a message;
// and a STARTTLS front, because GreenMail's SMTP port does not offer STARTTLS (iCloud's 587
// requires it). Both forward bytes to GreenMail unchanged; neither imitates a server.

/// Forwards bytes to its partner channel. Both channels of a pair share one event loop.
final class RelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    var partner: (any Channel)?
    private var pending: [ByteBuffer] = []
    /// Bytes to drop before forwarding anything (an upstream greeting to hide).
    var skipFirstLine = false
    /// Looks at each buffer; returns false to drop it and close both sides.
    var inspect: ((ByteBuffer) -> Bool)?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if skipFirstLine {
            guard let lf = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else { return }
            buffer.moveReaderIndex(to: lf + 1)
            skipFirstLine = false
            if buffer.readableBytes == 0 { return }
        }
        if let inspect, !inspect(buffer) {
            partner?.close(promise: nil)
            context.close(promise: nil)
            return
        }
        if let partner { partner.writeAndFlush(buffer, promise: nil) } else { pending.append(buffer) }
    }

    func attach(_ partner: any Channel) {
        self.partner = partner
        for buffer in pending { partner.write(buffer, promise: nil) }
        partner.flush()
        pending = []
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

/// A loopback TCP proxy in front of a test server port.
final class FaultProxy: Sendable {
    enum Mode: Sendable {
        case relay
        /// SMTP in plaintext: once the client has sent the end-of-data marker, swallow the
        /// server's reply and cut the connection. The server has the message; the client
        /// never learns it.
        case cutAfterEndOfData
    }

    private let server: any Channel
    private let connections = NIOLockedValueBox<[any Channel]>([])
    let port: Int

    init(targetPort: Int, mode: Mode = .relay) async throws {
        let connections = self.connections
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { child in
                connections.withLockedValue { $0.append(child) }
                let downstream = RelayHandler()
                let upstream = RelayHandler()
                if case .cutAfterEndOfData = mode {
                    let sawEnd = NIOLockedValueBox(false)
                    var tail: [UInt8] = []
                    downstream.inspect = { buffer in
                        tail += buffer.readableBytesView
                        if tail.count > 5 { tail.removeFirst(tail.count - 5) }
                        if tail == Array("\r\n.\r\n".utf8) { sawEnd.withLockedValue { $0 = true } }
                        return true
                    }
                    upstream.inspect = { _ in !sawEnd.withLockedValue { $0 } }
                }
                let boundDown = NIOLoopBound(downstream, eventLoop: child.eventLoop)
                let boundUp = NIOLoopBound(upstream, eventLoop: child.eventLoop)
                do {
                    try child.pipeline.syncOperations.addHandler(downstream)
                } catch {
                    return child.eventLoop.makeFailedFuture(error)
                }
                return ClientBootstrap(group: child.eventLoop)
                    .channelInitializer { up in
                        up.eventLoop.makeCompletedFuture { try up.pipeline.syncOperations.addHandler(boundUp.value) }
                    }
                    .connect(host: "127.0.0.1", port: targetPort)
                    .map { up in
                        connections.withLockedValue { $0.append(up) }
                        boundUp.value.attach(child)
                        boundDown.value.attach(up)
                    }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        self.server = server
        self.port = server.localAddress!.port!
    }

    /// Cuts every connection through the proxy, as a network failure would.
    func severAll() {
        for channel in connections.withLockedValue({ $0 }) { channel.close(promise: nil) }
    }

    func shutdown() async {
        severAll()
        try? await server.close()
    }
}

/// An SMTP front that offers STARTTLS, performs the TLS handshake with the test certificate,
/// then relays the decrypted session to GreenMail's plaintext SMTP port. The client talks TLS
/// to this front exactly as it would to smtp.mail.me.com:587.
final class StartTLSFront: Sendable {
    private let server: any Channel
    let port: Int

    init(targetPort: Int, certificate: URL, key: URL) async throws {
        let chain = try NIOSSLCertificate.fromPEMFile(certificate.path).map { NIOSSLCertificateSource.certificate($0) }
        let privateKey = try NIOSSLPrivateKey(file: key.path, format: .pem)
        let context = try NIOSSLContext(configuration: .makeServerConfiguration(
            certificateChain: chain, privateKey: .privateKey(privateKey)))
        self.server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { child in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(StartTLSFrontHandler(tls: context, targetPort: targetPort))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        self.port = server.localAddress!.port!
    }

    func shutdown() async {
        try? await server.close()
    }
}

private final class StartTLSFrontHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let tls: NIOSSLContext
    private let targetPort: Int
    private var buffer = ByteBuffer()
    private var relay: RelayHandler?

    init(tls: NIOSSLContext, targetPort: Int) {
        self.tls = tls
        self.targetPort = targetPort
    }

    func channelActive(context: ChannelHandlerContext) {
        reply(context, "220 localhost ESMTP STARTTLS test front\r\n")
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if let relay {
            relay.channelRead(context: context, data: NIOAny(incoming))
            return
        }
        buffer.writeBuffer(&incoming)
        while let lf = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer.readString(length: lf - buffer.readerIndex + 1)!.trimmingCharacters(in: .whitespacesAndNewlines)
            let verb = line.split(separator: " ").first.map { $0.uppercased() } ?? ""
            switch verb {
            case "EHLO", "HELO":
                reply(context, "250-localhost\r\n250 STARTTLS\r\n")
            case "STARTTLS":
                reply(context, "220 2.0.0 Ready to start TLS\r\n")
                startTLS(context)
                return
            case "QUIT":
                reply(context, "221 bye\r\n")
                context.close(promise: nil)
                return
            default:
                reply(context, "530 5.7.0 Must issue a STARTTLS command first\r\n")
            }
        }
    }

    private func startTLS(_ context: ChannelHandlerContext) {
        let relay = RelayHandler()
        self.relay = relay
        do {
            try context.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls), position: .first)
        } catch {
            context.close(promise: nil)
            return
        }
        let child = context.channel
        let upstreamRelay = RelayHandler()
        upstreamRelay.skipFirstLine = true // GreenMail's greeting; the client already had ours
        let boundUp = NIOLoopBound(upstreamRelay, eventLoop: child.eventLoop)
        let boundRelay = NIOLoopBound(relay, eventLoop: child.eventLoop)
        ClientBootstrap(group: child.eventLoop)
            .channelInitializer { up in
                up.eventLoop.makeCompletedFuture { try up.pipeline.syncOperations.addHandler(boundUp.value) }
            }
            .connect(host: "127.0.0.1", port: targetPort)
            .whenComplete { result in
                switch result {
                case .success(let up):
                    boundUp.value.attach(child)
                    boundRelay.value.attach(up)
                case .failure:
                    child.close(promise: nil)
                }
            }
    }

    private func reply(_ context: ChannelHandlerContext, _ text: String) {
        context.writeAndFlush(NIOAny(context.channel.allocator.buffer(string: text)), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        relay?.partner?.close(promise: nil)
        context.fireChannelInactive()
    }
}
