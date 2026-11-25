import Foundation
import MailNet
import MailProvider
import NIOConcurrencyHelpers
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL

/// The responses one command produced, up to and including its tagged completion.
struct IMAPCommandResult {
    var untagged: [ResponsePayload] = []
    var fetches: [IMAPFetchedAttributes] = []
    var tagged: TaggedResponse

    var isOK: Bool {
        if case .ok = tagged.state { true } else { false }
    }

    var responseText: ResponseText {
        switch tagged.state {
        case .ok(let text), .no(let text), .bad(let text): text
        }
    }

    /// Response codes from the tagged response and any untagged OK (MOVE reports COPYUID in an
    /// untagged OK, RFC 6851).
    var responseCodes: [ResponseTextCode] {
        var codes: [ResponseTextCode] = []
        for payload in untagged {
            if case .conditionalState(.ok(let text)) = payload, let code = text.code { codes.append(code) }
        }
        if let code = responseText.code { codes.append(code) }
        return codes
    }
}

/// One FETCH response, assembled from the codec's streaming parts.
struct IMAPFetchedAttributes {
    var sequenceNumber: SequenceNumber?
    var uid: UInt32?
    var attributes: [MessageAttribute] = []
    /// The whole message (`BODY[]`).
    var body: Data?
    /// Other body sections (`BODY[HEADER]`, `BODY[1.MIME]`, `BODY[2]`), GKM-036.
    var sections: [SectionSpecifier: Data] = [:]
}

/// One IMAP connection: writes commands and reads their responses, strictly one command at a
/// time. Lives inside `NIOAsyncChannel.executeThenClose`, so it never outlives its channel.
final class IMAPWire {
    private var inbound: NIOAsyncChannelInboundStream<Response>.AsyncIterator
    private let outbound: NIOAsyncChannelOutboundWriter<IMAPClientHandler.Message>
    private let channel: any Channel
    private let log: MailLog
    private let commandTimeout: Duration
    private var tagCounter = 0
    /// Set by a deadline that fired, so the resulting end of stream reads as a timeout.
    private let deadlineFired = NIOLockedValueBox(false)
    private(set) var isBroken = false
    /// Untagged responses that arrived between commands (EXISTS, EXPUNGE, FETCH FLAGS…).
    private(set) var unsolicited: [ResponsePayload] = []

    /// Caps one message body held in memory. Larger messages need streaming to disk (GKM-011).
    static let maximumBodySize = 64 * 1024 * 1024

    init(
        inbound: NIOAsyncChannelInboundStream<Response>,
        outbound: NIOAsyncChannelOutboundWriter<IMAPClientHandler.Message>,
        channel: any Channel,
        log: MailLog,
        commandTimeout: Duration
    ) {
        self.inbound = inbound.makeAsyncIterator()
        self.outbound = outbound
        self.channel = channel
        self.log = log
        self.commandTimeout = commandTimeout
    }

    func takeUnsolicited() -> [ResponsePayload] {
        defer { unsolicited = [] }
        return unsolicited
    }

    private func makeTag() -> Command.Tag {
        tagCounter += 1
        return Command.Tag("G\(tagCounter)")!
    }

    /// Closes the channel if nothing finishes `operation` in time. Reading is tied to the
    /// channel, so closing it is how a stuck read is ended.
    private func armTimeout(_ timeout: Duration, _ what: String) -> Scheduled<Void> {
        let channel = self.channel
        let log = self.log
        let fired = self.deadlineFired
        let nanos = Int64(timeout.components.seconds) * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000
        return channel.eventLoop.scheduleTask(in: .nanoseconds(nanos)) {
            fired.withLockedValue { $0 = true }
            log.warning("imap", "\(what) timed out after \(timeout); closing the connection")
            channel.close(promise: nil)
        }
    }

    /// Reads the next response, mapping the end of the stream to `connectionLost`.
    private func nextResponse() async throws -> Response {
        let timedOut = { self.deadlineFired.withLockedValue { $0 } }
        do {
            guard let response = try await inbound.next(isolation: #isolation) else {
                isBroken = true
                throw timedOut() ? MailProviderError.timedOut("IMAP response") : MailProviderError.connectionLost("the server closed the connection")
            }
            if case .fatal(let text) = response {
                isBroken = true
                throw MailProviderError.connectionLost("server said BYE: \(text.text)")
            }
            return response
        } catch let error as MailProviderError {
            throw error
        } catch {
            isBroken = true
            if timedOut() { throw MailProviderError.timedOut("IMAP response") }
            throw MailProviderError.connectionLost(MailNet.describe(error))
        }
    }

    /// Waits for the server greeting.
    func readGreeting() async throws -> ResponseText {
        let deadline = armTimeout(commandTimeout, "greeting")
        defer { deadline.cancel() }
        let response = try await nextResponse()
        switch response {
        case .untagged(.conditionalState(.ok(let text))):
            return text
        case .untagged(.conditionalState(.preauth(let text))):
            return text
        default:
            throw MailProviderError.protocolViolation("unexpected greeting")
        }
    }

    /// Sends one command and collects everything up to its tagged response.
    ///
    /// `logAs` is what goes to the log instead of the command; commands that carry a credential
    /// pass a fixed string, so the credential never reaches a formatter.
    func run(_ command: Command, logAs: String) async throws -> IMAPCommandResult {
        guard !isBroken else { throw MailProviderError.connectionLost("connection already failed") }
        let tag = makeTag()
        log.debug("imap", "→ \(String(tag)) \(logAs)")
        let deadline = armTimeout(commandTimeout, logAs)
        defer { deadline.cancel() }
        do {
            try await outbound.write(.part(.tagged(TaggedCommand(tag: tag, command: command))))
        } catch {
            isBroken = true
            throw MailProviderError.connectionLost(MailNet.describe(error))
        }
        return try await collect(tag: tag, logAs: logAs)
    }

    private func collect(tag: Command.Tag, logAs: String) async throws -> IMAPCommandResult {
        var untagged: [ResponsePayload] = []
        var fetches: [IMAPFetchedAttributes] = []
        var current: IMAPFetchedAttributes?
        var streaming: Data?
        var streamingKind: StreamingKind?
        while true {
            let response = try await nextResponse()
            switch response {
            case .tagged(let tagged) where tagged.tag == tag:
                let result = IMAPCommandResult(untagged: untagged, fetches: fetches, tagged: tagged)
                log.debug("imap", "← \(String(tag)) \(result.isOK ? "OK" : "NO/BAD") \(logAs)")
                return result
            case .tagged(let other):
                throw MailProviderError.protocolViolation("tagged response for unknown tag \(String(other.tag))")
            case .untagged(let payload):
                untagged.append(payload)
            case .fetch(let part):
                switch part {
                case .start(let sequence):
                    current = IMAPFetchedAttributes(sequenceNumber: sequence)
                case .startUID(let uid):
                    current = IMAPFetchedAttributes(uid: uid.rawValue)
                case .simpleAttribute(let attribute):
                    if case .uid(let uid) = attribute { current?.uid = uid.rawValue }
                    current?.attributes.append(attribute)
                case .streamingBegin(let kind, let byteCount):
                    guard byteCount <= Self.maximumBodySize else {
                        isBroken = true
                        throw MailProviderError.unsupported("message of \(byteCount) bytes is over the in-memory limit")
                    }
                    streaming = Data(capacity: byteCount)
                    streamingKind = kind
                case .streamingBytes(let bytes):
                    streaming?.append(contentsOf: bytes.readableBytesView)
                case .streamingEnd:
                    if case .body(let section, nil)? = streamingKind, !(Array(section.part).isEmpty && section.kind == .complete) {
                        current?.sections[section] = streaming ?? Data()
                    } else {
                        current?.body = streaming
                    }
                    streaming = nil
                    streamingKind = nil
                case .finish:
                    if let finished = current { fetches.append(finished) }
                    current = nil
                }
            case .fatal(let text):
                isBroken = true
                throw MailProviderError.connectionLost("server said BYE: \(text.text)")
            case .authenticationChallenge, .idleStarted:
                throw MailProviderError.protocolViolation("unexpected continuation during \(logAs)")
            }
        }
    }

    /// AUTHENTICATE with a SASL initial response (RFC 4959). A server that answers with a
    /// challenge (XOAUTH2 does that to report an error) gets an empty response, after which it
    /// sends the tagged NO.
    func authenticate(mechanism: String, initialResponse: [UInt8]) async throws -> IMAPCommandResult {
        guard let mechanism = AuthenticationMechanism(mechanism) else {
            throw MailProviderError.unsupported("SASL mechanism \(mechanism)")
        }
        let tag = makeTag()
        log.debug("imap", "→ \(String(tag)) AUTHENTICATE \(mechanism) ‹initial response redacted›")
        let deadline = armTimeout(commandTimeout, "AUTHENTICATE")
        defer { deadline.cancel() }
        var buffer = channel.allocator.buffer(capacity: initialResponse.count)
        buffer.writeBytes(initialResponse)
        do {
            try await outbound.write(.part(.tagged(TaggedCommand(
                tag: tag,
                command: .authenticate(mechanism: mechanism, initialResponse: InitialResponse(buffer))
            ))))
        } catch {
            isBroken = true
            throw MailProviderError.connectionLost(MailNet.describe(error))
        }
        var untagged: [ResponsePayload] = []
        while true {
            let response = try await nextResponse()
            switch response {
            case .authenticationChallenge:
                try await outbound.write(.part(.continuationResponse(channel.allocator.buffer(capacity: 0))))
            case .tagged(let tagged) where tagged.tag == tag:
                return IMAPCommandResult(untagged: untagged, fetches: [], tagged: tagged)
            case .untagged(let payload):
                untagged.append(payload)
            default:
                throw MailProviderError.protocolViolation("unexpected response during AUTHENTICATE")
            }
        }
    }

    /// APPEND one message (RFC 3501 6.3.11). The codec waits for the server's continuation
    /// before sending the literal, unless the server has LITERAL+.
    func append(_ message: Data, to mailbox: MailboxName, flags: [Flag]) async throws -> IMAPCommandResult {
        let tag = makeTag()
        log.debug("imap", "→ \(String(tag)) APPEND (\(message.count) bytes)")
        let deadline = armTimeout(commandTimeout, "APPEND")
        defer { deadline.cancel() }
        var bytes = channel.allocator.buffer(capacity: message.count)
        bytes.writeBytes(message)
        do {
            try await outbound.write(contentsOf: [
                .part(.append(.start(tag: tag, appendingTo: mailbox))),
                .part(.append(.beginMessage(message: AppendMessage(
                    options: AppendOptions(flagList: flags, internalDate: nil, extensions: [:]),
                    data: AppendData(byteCount: message.count)
                )))),
                .part(.append(.messageBytes(bytes))),
                .part(.append(.endMessage)),
                .part(.append(.finish)),
            ])
        } catch {
            isBroken = true
            throw MailProviderError.connectionLost(MailNet.describe(error))
        }
        return try await collect(tag: tag, logAs: "APPEND")
    }

    /// IDLE (RFC 2177) until the selected mailbox changes or `timeout` passes, then DONE.
    func idle(timeout: Duration) async throws -> MailboxEvent {
        let tag = makeTag()
        log.debug("imap", "→ \(String(tag)) IDLE (up to \(timeout))")
        do {
            try await outbound.write(.part(.tagged(TaggedCommand(tag: tag, command: .idleStart))))
        } catch {
            isBroken = true
            throw MailProviderError.connectionLost(MailNet.describe(error))
        }
        let outbound = self.outbound
        let doneSent = DoneLatch()
        let sendDone: @Sendable () async -> Void = {
            guard doneSent.claim() else { return }
            try? await outbound.write(.part(.idleDone))
        }
        // The server must answer DONE within the normal command timeout.
        let hardDeadline = armTimeout(timeout + commandTimeout, "IDLE")
        defer { hardDeadline.cancel() }

        return try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(for: timeout)
                await sendDone()
            }
            defer { group.cancelAll() }
            var event = MailboxEvent.timedOut
            while true {
                let response = try await nextResponse()
                switch response {
                case .idleStarted:
                    continue
                case .untagged(let payload):
                    switch payload {
                    case .mailboxData(.exists), .messageData(.expunge), .messageData(.vanished), .mailboxData(.recent):
                        event = .changed
                        unsolicited.append(payload)
                        await sendDone()
                    default:
                        unsolicited.append(payload)
                    }
                case .fetch(.finish):
                    // A flag change pushed while idling (`* n FETCH (FLAGS …)`).
                    event = .changed
                    await sendDone()
                case .fetch:
                    continue
                case .tagged(let tagged) where tagged.tag == tag:
                    if case .ok = tagged.state {
                        log.debug("imap", "← \(String(tag)) IDLE ended: \(event)")
                        return event
                    }
                    throw MailProviderError.commandFailed("IDLE refused")
                default:
                    throw MailProviderError.protocolViolation("unexpected response during IDLE")
                }
            }
        }
    }

    func dropForTesting() {
        channel.close(promise: nil)
    }

    func close() async {
        try? await channel.close()
    }
}

/// Makes sure DONE is written once, whichever of timeout and change comes first.
final class DoneLatch: Sendable {
    private let claimed = NIOLockedValueBox(false)
    func claim() -> Bool {
        claimed.withLockedValue { value in
            if value { return false }
            value = true
            return true
        }
    }
}
