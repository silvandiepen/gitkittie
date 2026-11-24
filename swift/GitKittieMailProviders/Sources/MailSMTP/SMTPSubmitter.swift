import Foundation
import MailNet
import MailProvider
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL

/// Deliberate failures for proving the uncertain-send path, against a real server.
public enum SMTPFaultInjection: Sendable, Hashable {
    /// After the end of the message has gone out, wait until the server's reply has arrived,
    /// then drop the connection without reading it: the server has the message, the client
    /// cannot know. The outcome must be `.uncertain`, never `.notSent`.
    case loseFinalReply
}

/// Message submission over SMTP (RFC 6409), one transaction per connection.
///
/// It reports exactly how far a transaction got (``SubmissionOutcome``): anything that fails
/// before the end-of-data marker is written is `notSent`; anything after it without a reply is
/// `uncertain`. It never retries by itself.
public struct SMTPSubmitter: MailSubmitter {
    public var endpoint: ServerEndpoint
    public var credential: MailCredential
    public var log: MailLog
    /// The name in EHLO. An address literal by default, so the machine's host name does not
    /// leak into every message's Received header.
    public var clientName: String
    public var replyTimeout: Duration
    /// RFC 5321 4.5.3.2.6 suggests 10 minutes for the reply to the end of data.
    public var finalReplyTimeout: Duration
    @_spi(FaultInjection) public var faultInjection: SMTPFaultInjection?

    public init(endpoint: ServerEndpoint, credential: MailCredential, log: MailLog = .disabled,
                clientName: String = "[127.0.0.1]", replyTimeout: Duration = .seconds(60),
                finalReplyTimeout: Duration = .seconds(600)) {
        self.endpoint = endpoint
        self.credential = credential
        self.log = log.scrubbing([credential.secret])
        self.clientName = clientName
        self.replyTimeout = replyTimeout
        self.finalReplyTimeout = finalReplyTimeout
    }

    public func submit(_ message: OutgoingMessage) async -> SubmissionOutcome {
        let transaction = SMTPTransaction(submitter: self)
        let outcome = await transaction.run(message)
        switch outcome {
        case .accepted(let reply): log.info("smtp", "accepted <\(message.messageID)>: \(reply)")
        case .notSent(let reason, let permanent): log.warning("smtp", "not sent <\(message.messageID)> (\(permanent ? "permanent" : "temporary")): \(reason)")
        case .uncertain(let reason): log.error("smtp", "UNCERTAIN <\(message.messageID)>: \(reason); reconcile before any retry")
        }
        return outcome
    }

    /// Connects, starts TLS, signs in and says goodbye, without sending anything: how account
    /// setup checks the outgoing server before saving (GKM-010). Throws
    /// ``MailProviderError/authenticationFailed(_:)`` when the server refuses the credentials,
    /// `connectionFailed` when it cannot be reached or its certificate is not trusted, and
    /// `unsupported` when it offers no STARTTLS or no usable sign-in.
    public func verifySignIn() async throws {
        let transaction = SMTPTransaction(submitter: self)
        defer { transaction.channel?.close(promise: nil) }
        do {
            try await transaction.handshake()
            await transaction.quit()
            log.info("smtp", "sign-in check passed for \(endpoint)")
        } catch let failure as SMTPFailure {
            await transaction.quit()
            log.warning("smtp", "sign-in check failed: \(failure.reason)")
            if failure.isAuthentication { throw MailProviderError.authenticationFailed(failure.reason) }
            throw failure.permanent ? MailProviderError.unsupported(failure.reason) : MailProviderError.commandFailed(failure.reason)
        }
    }
}

/// Where a transaction failed, which decides the outcome.
enum Phase {
    case beforeData
    /// The end-of-data marker may have reached the server.
    case awaitingFinalReply
}

struct SMTPFailure: Error {
    var reason: String
    var permanent: Bool
    /// The server refused the credentials (not: offered no mechanism).
    var isAuthentication = false
}

final class SMTPTransaction {
    let submitter: SMTPSubmitter
    var log: MailLog { submitter.log }
    var channel: (any Channel)?
    var replies: AsyncThrowingStream<SMTPReply, any Error>.AsyncIterator?
    var decoder: NIOLoopBound<SMTPReplyDecoder>?
    var extensions: [String: String] = [:]
    var phase = Phase.beforeData
    let deadlineFired = NIOLockedValueBox(false)

    init(submitter: SMTPSubmitter) {
        self.submitter = submitter
    }

    func run(_ message: OutgoingMessage) async -> SubmissionOutcome {
        defer { channel?.close(promise: nil) }
        do {
            let accepted = try await transact(message)
            await quit()
            return .accepted(serverReply: accepted.description)
        } catch let failure as SMTPFailure {
            await quit()
            return .notSent(reason: failure.reason, permanent: failure.permanent)
        } catch {
            let reason = (error as? MailProviderError)?.description ?? MailNet.describe(error)
            switch phase {
            case .beforeData:
                // The server cannot have taken a message whose end it never saw.
                let permanent = (error as? MailProviderError).map { !$0.isConnectionProblem } ?? false
                return .notSent(reason: reason, permanent: permanent)
            case .awaitingFinalReply:
                return .uncertain(reason: reason)
            }
        }
    }

    // MARK: - The transaction

    private func transact(_ message: OutgoingMessage) async throws -> SMTPReply {
        let endpoint = submitter.endpoint
        try MailNet.checkPlaintextAllowed(endpoint)
        try Self.validate(address: message.envelopeFrom)
        guard !message.recipients.isEmpty else { throw SMTPFailure(reason: "no recipients", permanent: true) }
        for recipient in message.recipients { try Self.validate(address: recipient) }

        try await handshake()

        let payload = Self.dotStuffed(message.rawMessage)
        if let limit = extensions["SIZE"].flatMap({ Int($0) }), limit > 0, message.rawMessage.count > limit {
            throw SMTPFailure(reason: "message is \(message.rawMessage.count) bytes; the server accepts \(limit)", permanent: true)
        }
        var mailFrom = "MAIL FROM:<\(message.envelopeFrom)>"
        if extensions["SIZE"] != nil { mailFrom += " SIZE=\(message.rawMessage.count)" }
        if extensions["8BITMIME"] != nil, message.rawMessage.contains(where: { $0 >= 0x80 }) { mailFrom += " BODY=8BITMIME" }
        try await send(mailFrom)
        try await expectSuccess("MAIL FROM")

        var rejected: [String] = []
        var allPermanent = true
        for recipient in message.recipients {
            try await send("RCPT TO:<\(recipient)>")
            let reply = try await nextReply("RCPT TO")
            if !reply.isPositiveCompletion {
                rejected.append("\(recipient): \(reply)")
                allPermanent = allPermanent && reply.isPermanentFailure
            }
        }
        if !rejected.isEmpty {
            // All or nothing: a message that reaches only some recipients is worse than one
            // that reaches none and says why.
            try? await send("RSET")
            _ = try? await nextReply("RSET")
            throw SMTPFailure(reason: "recipients refused: \(rejected.joined(separator: "; "))", permanent: allPermanent)
        }

        try await send("DATA")
        let dataReply = try await nextReply("DATA")
        guard dataReply.code == 354 else {
            throw SMTPFailure(reason: "DATA refused: \(dataReply)", permanent: dataReply.isPermanentFailure)
        }
        log.debug("smtp", "→ message (\(payload.count) bytes)")
        try await write(payload)
        // From here on the server may have the whole message.
        phase = .awaitingFinalReply
        log.debug("smtp", "→ .")
        try await write(Data(".\r\n".utf8))

        if submitter.faultInjection == .loseFinalReply {
            _ = try await nextReply("end of data", timeout: submitter.finalReplyTimeout)
            log.warning("smtp", "fault injection: dropping the connection without reading the final reply")
            channel?.close(promise: nil)
            throw MailProviderError.connectionLost("connection dropped before the reply to the end of data (injected)")
        }
        let final = try await nextReply("end of data", timeout: submitter.finalReplyTimeout)
        log.debug("smtp", "← \(final.code) end of data")
        guard final.isPositiveCompletion else {
            // The server answered, so it has decided: it did not take the message.
            throw SMTPFailure(reason: "message refused: \(final)", permanent: final.isPermanentFailure)
        }
        return final
    }

    /// Connect, greeting, EHLO, STARTTLS when asked for, sign-in.
    func handshake() async throws {
        let endpoint = submitter.endpoint
        try MailNet.checkPlaintextAllowed(endpoint)
        try await connect()
        let greeting = try await expect(220, "greeting")
        log.debug("smtp", "← \(greeting.code) greeting")
        try await ehlo()

        if endpoint.security == .startTLS {
            guard extensions["STARTTLS"] != nil else {
                // Never fall back to plaintext: that is exactly what a downgrade attack wants.
                throw SMTPFailure(reason: "the server does not offer STARTTLS; refusing to continue without TLS", permanent: true)
            }
            try await setExpectingUpgrade()
            try await send("STARTTLS")
            _ = try await expect(220, "STARTTLS")
            try await installTLS()
            extensions = [:]
            try await ehlo()
        }

        try await authenticate()
    }

    private func ehlo() async throws {
        try await send("EHLO \(submitter.clientName)")
        let reply = try await nextReply("EHLO")
        guard reply.isPositiveCompletion else {
            throw SMTPFailure(reason: "EHLO refused: \(reply)", permanent: reply.isPermanentFailure)
        }
        extensions = [:]
        for line in reply.lines.dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let keyword = parts.first else { continue }
            extensions[keyword.uppercased()] = parts.count > 1 ? String(parts[1]) : ""
        }
        log.debug("smtp", "server extensions: \(extensions.keys.sorted().joined(separator: " "))")
    }

    private func authenticate() async throws {
        let mechanisms = Set((extensions["AUTH"] ?? "").uppercased().split(separator: " ").map(String.init))
        switch submitter.credential {
        case .password(let username, let password):
            if mechanisms.contains("PLAIN") {
                let token = password.withValue { Data("\0\(username)\0\($0)".utf8).base64EncodedString() }
                try await send("AUTH PLAIN \(token)", logAs: "AUTH PLAIN \(Redaction.placeholder)")
            } else if mechanisms.contains("LOGIN") {
                try await send("AUTH LOGIN")
                try await expect(334, "AUTH LOGIN")
                try await send(Data(username.utf8).base64EncodedString(), logAs: "‹user name›")
                try await expect(334, "AUTH LOGIN user")
                try await send(password.withValue { Data($0.utf8).base64EncodedString() }, logAs: Redaction.placeholder)
            } else {
                throw SMTPFailure(reason: "the server offers no password mechanism (AUTH \(mechanisms.sorted().joined(separator: " ")))", permanent: true)
            }
        case .oauth2(let username, let token):
            guard mechanisms.contains("XOAUTH2") else {
                throw SMTPFailure(reason: "the server does not offer AUTH XOAUTH2", permanent: true)
            }
            let response = token.withValue { Data("user=\(username)\u{1}auth=Bearer \($0)\u{1}\u{1}".utf8).base64EncodedString() }
            try await send("AUTH XOAUTH2 \(response)", logAs: "AUTH XOAUTH2 \(Redaction.placeholder)")
        }
        var reply = try await nextReply("AUTH")
        if reply.code == 334 {
            // XOAUTH2 reports an error as a challenge; an empty line ends the exchange.
            try await send("")
            reply = try await nextReply("AUTH")
        }
        guard reply.code == 235 else {
            throw SMTPFailure(reason: "authentication failed: \(reply)", permanent: !reply.isTransientFailure, isAuthentication: true)
        }
        log.debug("smtp", "authenticated")
    }

    func quit() async {
        guard let channel, channel.isActive else { return }
        try? await send("QUIT")
        _ = try? await nextReply("QUIT", timeout: .seconds(5))
    }

    // MARK: - Transport

    private func connect() async throws {
        let endpoint = submitter.endpoint
        log.info("smtp", "connecting to \(endpoint)")
        let (stream, continuation) = AsyncThrowingStream<SMTPReply, any Error>.makeStream()
        let tlsContext = endpoint.security == .implicitTLS ? try MailNet.makeTLSContext(endpoint.trust) : nil
        let channel: any Channel
        do {
            channel = try await MailNet.makeBootstrap(for: endpoint)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        if let tlsContext {
                            try channel.pipeline.syncOperations.addHandler(
                                NIOSSLClientHandler(context: tlsContext, serverHostname: endpoint.host))
                        }
                        try channel.pipeline.syncOperations.addHandler(SMTPReplyDecoder(continuation: continuation))
                    }
                }
                .connect(host: endpoint.host, port: endpoint.port).get()
        } catch {
            throw MailProviderError.connectionFailed(MailNet.describe(error))
        }
        self.channel = channel
        self.replies = stream.makeAsyncIterator()
        self.decoder = try await channel.eventLoop.submit {
            NIOLoopBound(try channel.pipeline.syncOperations.handler(type: SMTPReplyDecoder.self), eventLoop: channel.eventLoop)
        }.get()
    }

    private func setExpectingUpgrade() async throws {
        guard let channel, let decoder else { throw MailProviderError.connectionLost("not connected") }
        try await channel.eventLoop.submit { decoder.value.expectingTLSUpgrade = true }.get()
    }

    private func installTLS() async throws {
        guard let channel, let decoder else { throw MailProviderError.connectionLost("not connected") }
        let endpoint = submitter.endpoint
        let context = try MailNet.makeTLSContext(endpoint.trust)
        try await channel.eventLoop.submit {
            let handler = try NIOSSLClientHandler(context: context, serverHostname: endpoint.host)
            try channel.pipeline.syncOperations.addHandler(handler, position: .first)
            decoder.value.tlsInstalled()
        }.get()
        log.debug("smtp", "TLS started")
    }

    private func send(_ line: String, logAs: String? = nil) async throws {
        guard !line.contains("\r"), !line.contains("\n") else {
            throw SMTPFailure(reason: "line break inside an SMTP command", permanent: true)
        }
        log.debug("smtp", "→ \(logAs ?? line)")
        try await write(Data((line + "\r\n").utf8))
    }

    private func write(_ data: Data) async throws {
        guard let channel else { throw MailProviderError.connectionLost("not connected") }
        do {
            try await channel.writeAndFlush(channel.allocator.buffer(bytes: data))
        } catch {
            throw MailProviderError.connectionLost(MailNet.describe(error))
        }
    }

    private func nextReply(_ what: String, timeout: Duration? = nil) async throws -> SMTPReply {
        guard let channel else { throw MailProviderError.connectionLost("not connected") }
        let timeout = timeout ?? submitter.replyTimeout
        let fired = deadlineFired
        let log = self.log
        let nanos = Int64(timeout.components.seconds) * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000
        let deadline = channel.eventLoop.scheduleTask(in: .nanoseconds(nanos)) {
            fired.withLockedValue { $0 = true }
            log.warning("smtp", "no reply to \(what) within \(timeout)")
            channel.close(promise: nil)
        }
        defer { deadline.cancel() }
        do {
            guard let reply = try await replies?.next(isolation: #isolation) else {
                throw fired.withLockedValue({ $0 })
                    ? MailProviderError.timedOut("reply to \(what)")
                    : MailProviderError.connectionLost("the server closed the connection during \(what)")
            }
            log.trace("smtp", "← \(reply.code)")
            return reply
        } catch let error as MailProviderError {
            throw error
        } catch {
            if fired.withLockedValue({ $0 }) { throw MailProviderError.timedOut("reply to \(what)") }
            throw MailProviderError.connectionLost(MailNet.describe(error))
        }
    }

    @discardableResult
    private func expect(_ code: Int, _ what: String) async throws -> SMTPReply {
        let reply = try await nextReply(what)
        guard reply.code == code else {
            throw SMTPFailure(reason: "\(what): expected \(code), got \(reply)", permanent: reply.isPermanentFailure)
        }
        return reply
    }

    private func expectSuccess(_ what: String) async throws {
        let reply = try await nextReply(what)
        guard reply.isPositiveCompletion else {
            throw SMTPFailure(reason: "\(what) refused: \(reply)", permanent: reply.isPermanentFailure)
        }
    }

    // MARK: - Encoding

    /// Refuses anything that could break out of `<…>` in MAIL FROM / RCPT TO.
    static func validate(address: String) throws {
        let forbidden = CharacterSet(charactersIn: "<>\r\n\0 ")
        guard !address.isEmpty, address.rangeOfCharacter(from: forbidden) == nil, address.contains("@") else {
            throw SMTPFailure(reason: "invalid envelope address", permanent: true)
        }
    }

    /// The DATA payload (RFC 5321 4.5.2): every line ends in CRLF (a bare CR or LF becomes CRLF,
    /// which closes the SMTP smuggling hole), a leading "." is doubled, and the payload ends
    /// with CRLF so the terminator stands on its own line.
    static func dotStuffed(_ message: Data) -> Data {
        var out = Data()
        out.reserveCapacity(message.count + message.count / 50 + 2)
        var atLineStart = true
        var index = message.startIndex
        while index < message.endIndex {
            let byte = message[index]
            if byte == 0x0D || byte == 0x0A {
                out.append(contentsOf: [0x0D, 0x0A])
                if byte == 0x0D, message.index(after: index) < message.endIndex, message[message.index(after: index)] == 0x0A {
                    index = message.index(after: index)
                }
                atLineStart = true
            } else {
                if atLineStart && byte == UInt8(ascii: ".") { out.append(UInt8(ascii: ".")) }
                out.append(byte)
                atLineStart = false
            }
            index = message.index(after: index)
        }
        if !atLineStart { out.append(contentsOf: [0x0D, 0x0A]) }
        return out
    }
}
