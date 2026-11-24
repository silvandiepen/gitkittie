import Foundation
import MailProvider
import NIOCore

/// One SMTP reply (RFC 5321 4.2): a code and its text lines.
public struct SMTPReply: Sendable, Hashable, CustomStringConvertible {
    public var code: Int
    public var lines: [String]

    public var isPositiveCompletion: Bool { (200..<300).contains(code) }
    public var isPositiveIntermediate: Bool { (300..<400).contains(code) }
    public var isTransientFailure: Bool { (400..<500).contains(code) }
    public var isPermanentFailure: Bool { (500..<600).contains(code) }

    public var text: String { lines.joined(separator: " ") }
    public var description: String { "\(code) \(text)" }
}

/// Decodes SMTP replies and hands them to an async stream.
///
/// It is also the STARTTLS guard: between the server's `220` to STARTTLS and the TLS handler
/// taking over, any further byte is an attack (plaintext injected ahead of the handshake,
/// CVE-2011-0411 style), so the connection fails instead.
final class SMTPReplyDecoder: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    static let maximumLineLength = 4096
    static let maximumLines = 200

    private let continuation: AsyncThrowingStream<SMTPReply, any Error>.Continuation
    private var buffer = ByteBuffer()
    private var pendingLines: [String] = []
    private var pendingCode: Int?
    /// Set when the client has sent STARTTLS: the next reply must be the last plaintext.
    var expectingTLSUpgrade = false
    private var upgradeReplyDelivered = false

    init(continuation: AsyncThrowingStream<SMTPReply, any Error>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if upgradeReplyDelivered {
            fail(context: context, MailProviderError.protocolViolation("data after the STARTTLS reply, before TLS"))
            return
        }
        buffer.writeBuffer(&incoming)
        do {
            while let line = try nextLine() {
                if let reply = try consume(line) {
                    continuation.yield(reply)
                    if expectingTLSUpgrade {
                        upgradeReplyDelivered = true
                        if buffer.readableBytes > 0 {
                            throw MailProviderError.protocolViolation("data after the STARTTLS reply, before TLS")
                        }
                        return
                    }
                }
            }
            if buffer.readableBytes > Self.maximumLineLength {
                throw MailProviderError.protocolViolation("SMTP reply line too long")
            }
        } catch {
            fail(context: context, error)
        }
    }

    /// Called once the TLS handler is in place, so TLS-decrypted replies flow again.
    func tlsInstalled() {
        expectingTLSUpgrade = false
        upgradeReplyDelivered = false
    }

    private func nextLine() throws -> String? {
        let view = buffer.readableBytesView
        guard let lf = view.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let length = lf - view.startIndex
        guard length <= Self.maximumLineLength else {
            throw MailProviderError.protocolViolation("SMTP reply line too long")
        }
        var bytes = buffer.readBytes(length: length + 1)!
        bytes.removeLast()
        if bytes.last == UInt8(ascii: "\r") { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func consume(_ line: String) throws -> SMTPReply? {
        let scalars = Array(line.utf8)
        guard scalars.count >= 3,
              let code = Int(String(decoding: scalars[0..<3], as: UTF8.self)),
              (200..<600).contains(code)
        else { throw MailProviderError.protocolViolation("malformed SMTP reply") }
        let separator: UInt8? = scalars.count > 3 ? scalars[3] : nil
        let text = scalars.count > 4 ? String(decoding: scalars[4...], as: UTF8.self) : ""
        if let pendingCode, pendingCode != code {
            throw MailProviderError.protocolViolation("SMTP reply code changed inside a multi-line reply")
        }
        pendingLines.append(text)
        guard pendingLines.count <= Self.maximumLines else {
            throw MailProviderError.protocolViolation("SMTP reply has too many lines")
        }
        if separator == UInt8(ascii: "-") {
            pendingCode = code
            return nil
        }
        defer { pendingLines = []; pendingCode = nil }
        return SMTPReply(code: code, lines: pendingLines)
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        fail(context: context, error)
    }

    private func fail(context: ChannelHandlerContext, _ error: any Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }
}
