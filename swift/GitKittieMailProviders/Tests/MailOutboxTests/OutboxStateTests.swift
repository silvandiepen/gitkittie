import Foundation
import MailCompose
import MailCore
import MailMIME
import MailProvider
import NIOConcurrencyHelpers
import XCTest
@testable import MailOutbox

// The outbox's state machine and journal, without a network. The submitter here only replays
// outcomes the real SMTP client produces; what those outcomes mean on a real server, with real
// connection cuts, is proven in MailIntegrationTests/OutboxIntegrationTests.

final class ManualClock: OutboxClock, Sendable {
    private let current = NIOLockedValueBox(Date(timeIntervalSince1970: 1_795_000_000))
    func now() -> Date { current.withLockedValue { $0 } }
    func advance(_ seconds: TimeInterval) { current.withLockedValue { $0 = $0.addingTimeInterval(seconds) } }
}

/// Replays SMTP outcomes in order and records what it was asked to send.
final class ReplayingSubmitter: MailSubmitter, Sendable {
    private let state: NIOLockedValueBox<(outcomes: [SubmissionOutcome], sent: [OutgoingMessage])>
    init(_ outcomes: [SubmissionOutcome]) { state = NIOLockedValueBox((outcomes, [])) }
    var submitted: [OutgoingMessage] { state.withLockedValue { $0.sent } }
    func submit(_ message: OutgoingMessage) async -> SubmissionOutcome {
        state.withLockedValue { state in
            state.sent.append(message)
            return state.outcomes.isEmpty ? .accepted(serverReply: "250 OK") : state.outcomes.removeFirst()
        }
    }
}

struct ReplayTransport: OutboxTransport {
    let submitter: ReplayingSubmitter
    func submitter(for account: any SendingAccount) async throws -> any MailSubmitter { submitter }
    func mailbox(for account: any SendingAccount) async throws -> (any MailboxConnector)? { nil }
}

/// Holds a submission open until the test releases it, so a test can act while a send is in progress.
final class GatedSubmitter: MailSubmitter, Sendable {
    private let outcome: SubmissionOutcome
    private let started: AsyncStream<Void>.Continuation
    let startedStream: AsyncStream<Void>
    private let gate = NIOLockedValueBox<CheckedContinuation<Void, Never>?>(nil)
    private let opened = NIOLockedValueBox(false)

    init(outcome: SubmissionOutcome) {
        self.outcome = outcome
        (startedStream, started) = AsyncStream.makeStream(of: Void.self)
    }

    func submit(_ message: OutgoingMessage) async -> SubmissionOutcome {
        await withCheckedContinuation { continuation in
            let alreadyOpen = opened.withLockedValue { $0 }
            if alreadyOpen { continuation.resume() } else { gate.withLockedValue { $0 = continuation } }
            started.yield()
        }
        return outcome
    }

    func release() {
        opened.withLockedValue { $0 = true }
        gate.withLockedValue { $0?.resume(); $0 = nil }
    }
}

struct GatedTransport: OutboxTransport {
    let submitter: GatedSubmitter
    func submitter(for account: any SendingAccount) async throws -> any MailSubmitter { submitter }
    func mailbox(for account: any SendingAccount) async throws -> (any MailboxConnector)? { nil }
}

struct FixedDirectory: SendingAccountDirectory {
    let account: SendingAccountSettings?
    func sendingAccount(_ id: MailAccountID) async throws -> (any SendingAccount)? {
        account?.accountID == id ? account : nil
    }
}

final class OutboxStateTests: XCTestCase {
    private var folder: URL!
    private let clock = ManualClock()
    private let accountID = MailAccountID("acct-1")

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("gkm-outbox-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func account(_ policy: SentCopyPolicy = .providerFiles) -> SendingAccountSettings {
        SendingAccountSettings(
            accountID: accountID, identities: [MailAddress(address: "alex.morgan@example.net")],
            smtp: ServerEndpoint(host: "127.0.0.1", port: 1, security: .plaintextLoopbackOnly), imap: nil,
            credential: CredentialReference(service: "test", account: "acct-1", username: "alex.morgan@example.net"), sentCopy: policy)
    }

    private func open(_ submitter: ReplayingSubmitter, withoutAccount: Bool = false,
                      faults: OutboxFaults = .none) throws -> Outbox {
        var configuration = Outbox.Configuration()
        configuration.clock = clock
        configuration.random = { 0 }
        return try Outbox.open(folder: folder, accounts: FixedDirectory(account: withoutAccount ? nil : account()),
                               transport: ReplayTransport(submitter: submitter), configuration: configuration, faults: faults)
    }

    private func stored(_ outbox: Outbox, _ id: OperationID, file: StaticString = #filePath, line: UInt = #line) async throws -> OutboxEntry {
        let entry = await outbox.entry(id)
        return try XCTUnwrap(entry, file: file, line: line)
    }

    private func composed() throws -> (ComposedMessage, ComposeDraft) {
        let draft = ComposeDraft(account: accountID, from: MailAddress(name: "Alex", address: "alex.morgan@example.net"),
                                 to: [MailAddress(address: "kim@example.org")], bcc: [MailAddress(address: "hidden@example.com")],
                                 subject: "Plans", body: "Hello")
        return (try MessageComposer.compose(draft, attachments: []), draft)
    }

    func testEnqueueJournalsTheExactBytesBeforeReturning() async throws {
        let (message, draft) = try composed()
        let outbox = try open(ReplayingSubmitter([]))
        let entry = try await outbox.enqueue(message, account: accountID, draft: draft)
        XCTAssertEqual(entry.state, .queued)
        XCTAssertEqual(entry.recipients, ["kim@example.org", "hidden@example.com"])
        XCTAssertEqual(entry.bcc, ["hidden@example.com"])
        XCTAssertEqual(entry.visibleRecipients, ["kim@example.org"])
        await outbox.close()

        // A relaunch finds it, bytes and all.
        let reopened = try open(ReplayingSubmitter([]))
        let entries = await reopened.entries()
        XCTAssertEqual(entries.map(\.id), [entry.id])
        let raw = try await reopened.rawMessage(entry.id)
        XCTAssertEqual(raw, message.rawMessage)
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("hidden@example.com"))
        await reopened.close()
    }

    func testAcceptedIsSentOnceWithTheQueuedBytes() async throws {
        let (message, draft) = try composed()
        let submitter = ReplayingSubmitter([.accepted(serverReply: "250 2.0.0 OK")])
        let outbox = try open(submitter)
        let entry = try await outbox.enqueue(message, account: accountID, draft: draft)
        await outbox.processDue()
        await outbox.processDue()
        let sent = try await stored(outbox, entry.id)
        XCTAssertEqual(sent.state, .sent)
        XCTAssertEqual(sent.sentCopy, .filedByProvider, "Gmail-style providers file their own copy; no append")
        XCTAssertTrue(sent.isComplete)
        XCTAssertEqual(submitter.submitted.count, 1)
        XCTAssertEqual(submitter.submitted.first?.rawMessage, message.rawMessage)
        XCTAssertEqual(submitter.submitted.first?.messageID, message.messageID)
        XCTAssertEqual(submitter.submitted.first?.recipients, ["kim@example.org", "hidden@example.com"])
        XCTAssertEqual(sent.history.map(\.state), [.queued, .sending, .sent])

        // Kept for a day, then removed from the journal.
        clock.advance(25 * 3600)
        await outbox.processDue()
        let left = await outbox.entries()
        XCTAssertEqual(left, [])
        await outbox.close()
    }

    func testTemporaryFailuresRetryWithBackoffThenFail() async throws {
        let (message, draft) = try composed()
        let temporary = SubmissionOutcome.notSent(reason: "connection failed", permanent: false)
        let submitter = ReplayingSubmitter(Array(repeating: temporary, count: 5) + [.accepted(serverReply: "250")])
        let outbox = try open(submitter)
        let entry = try await outbox.enqueue(message, account: accountID, draft: draft)

        await outbox.processDue()
        var current = try await stored(outbox, entry.id)
        XCTAssertEqual(current.state, .queued)
        XCTAssertEqual(current.lastError, "connection failed")
        XCTAssertEqual(current.nextAttemptAt, clock.now().addingTimeInterval(30))

        // Not due yet: nothing happens.
        await outbox.processDue()
        XCTAssertEqual(submitter.submitted.count, 1)

        for _ in 0..<4 {
            clock.advance(3600)
            await outbox.processDue()
        }
        current = try await stored(outbox, entry.id)
        XCTAssertEqual(current.state, .failed, "five temporary failures give up")
        XCTAssertEqual(submitter.submitted.count, 5)
        XCTAssertEqual(Set(submitter.submitted.map(\.messageID)), [message.messageID], "every attempt is the same message")

        clock.advance(3600)
        await outbox.processDue()
        XCTAssertEqual(submitter.submitted.count, 5, "a failed send waits for the person")

        try await outbox.retry(entry.id)
        await outbox.processDue()
        current = try await stored(outbox, entry.id)
        XCTAssertEqual(current.state, .sent)
        XCTAssertEqual(submitter.submitted.count, 6)
        await outbox.close()
    }

    func testPermanentRefusalFailsAtOnce() async throws {
        let (message, draft) = try composed()
        let submitter = ReplayingSubmitter([.notSent(reason: "550 no such user", permanent: true)])
        let outbox = try open(submitter)
        let entry = try await outbox.enqueue(message, account: accountID, draft: draft)
        await outbox.processDue()
        let failed = try await stored(outbox, entry.id)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.lastError, "550 no such user")
        XCTAssertTrue(failed.canRetry && failed.canCancel && !failed.canSendAgain)
        await outbox.close()
    }

    /// The P0: an uncertain outcome is never resent by the outbox, however often it runs.
    func testUncertainIsNeverResentAutomatically() async throws {
        let (message, draft) = try composed()
        let submitter = ReplayingSubmitter([.uncertain(reason: "connection lost after the end of data")])
        let outbox = try open(submitter)
        let entry = try await outbox.enqueue(message, account: accountID, draft: draft)
        for _ in 0..<10 {
            await outbox.processDue()
            clock.advance(3600)
        }
        let uncertain = try await stored(outbox, entry.id)
        XCTAssertEqual(uncertain.state, .uncertain)
        XCTAssertEqual(submitter.submitted.count, 1)
        XCTAssertTrue(uncertain.lastError?.contains("Couldn’t check Sent") == true, uncertain.lastError ?? "")
        XCTAssertFalse(uncertain.canRetry)

        // Send Again needs a check at the provider; without mailbox access it is refused.
        do {
            try await outbox.sendAgain(entry.id)
            XCTFail("send again without a check must be refused")
        } catch OutboxError.cannotCheck {}
        XCTAssertEqual(submitter.submitted.count, 1)
        await outbox.close()
    }

    /// A process killed after `sending` reached the disk comes back uncertain, not queued.
    func testACrashMidSendComesBackUncertain() async throws {
        let (message, draft) = try composed()
        let submitter = ReplayingSubmitter([])
        let dying = try open(submitter, faults: OutboxFaults { step in
            if step == .markedSending { throw SimulatedStop() }
        })
        let entry = try await dying.enqueue(message, account: accountID, draft: draft)
        await dying.processDue()
        XCTAssertEqual(submitter.submitted.count, 0)
        await dying.close()

        let relaunched = try open(submitter)
        let recovered = try await stored(relaunched, entry.id)
        XCTAssertEqual(recovered.state, .uncertain)
        XCTAssertEqual(recovered.history.last?.note, "recovered after the app stopped mid-send")
        for _ in 0..<3 {
            await relaunched.processDue()
            clock.advance(3600)
        }
        XCTAssertEqual(submitter.submitted.count, 0, "never resent blindly")
        await relaunched.close()
    }

    /// Killed after the server accepted, before that was written down: still uncertain, and
    /// still not resent.
    func testACrashAfterAcceptanceIsNotResent() async throws {
        let (message, draft) = try composed()
        let submitter = ReplayingSubmitter([.accepted(serverReply: "250")])
        let dying = try open(submitter, faults: OutboxFaults { step in
            if case .submitted = step { throw SimulatedStop() }
        })
        let entry = try await dying.enqueue(message, account: accountID, draft: draft)
        await dying.processDue()
        await dying.close()

        let relaunched = try open(submitter)
        await relaunched.processDue()
        let recovered = try await stored(relaunched, entry.id)
        XCTAssertEqual(recovered.state, .uncertain)
        XCTAssertEqual(submitter.submitted.count, 1)
        await relaunched.close()
    }

    func testOnlyOneProcessOwnsTheOutbox() async throws {
        let first = try open(ReplayingSubmitter([]))
        XCTAssertThrowsError(try open(ReplayingSubmitter([]))) { XCTAssertEqual($0 as? OutboxError, .ownedByAnotherProcess) }
        await first.close()
        let second = try open(ReplayingSubmitter([]))
        await second.close()
    }

    func testAHalfWrittenEnqueueIsRemovedOnOpen() async throws {
        // What a crash inside enqueue leaves: the bytes, no entry. Send never returned, so the
        // draft still exists; nothing may be sent from this.
        let leftover = folder.appendingPathComponent(OperationID().rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("Subject: x\r\n\r\nx".utf8).write(to: leftover.appendingPathComponent("message.eml"))
        let submitter = ReplayingSubmitter([])
        let outbox = try open(submitter)
        await outbox.processDue()
        let entries = await outbox.entries()
        XCTAssertEqual(entries, [])
        XCTAssertEqual(submitter.submitted.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        await outbox.close()
    }

    func testCancelGivesTheDraftBackAndRefusesASentMessage() async throws {
        let (message, draft) = try composed()
        let outbox = try open(ReplayingSubmitter([]), withoutAccount: true)
        let entry = try await outbox.enqueue(message, account: accountID, draft: draft)
        // No account settings on this Mac: it waits, visibly, and sends nothing.
        await outbox.processDue()
        let waiting = try await stored(outbox, entry.id)
        XCTAssertEqual(waiting.state, .queued)
        XCTAssertEqual(waiting.attempts, 0)
        XCTAssertEqual(waiting.lastError, "The account isn’t set up for sending on this Mac.")

        let cancelled = try await outbox.cancel(entry.id)
        XCTAssertEqual(cancelled.entry.draft, draft)
        XCTAssertEqual(cancelled.rawMessage, message.rawMessage)
        let left = await outbox.entries()
        XCTAssertEqual(left, [])
        await outbox.close()

        let submitter = ReplayingSubmitter([])
        let sending = try open(submitter)
        let other = try await sending.enqueue(message, account: accountID, draft: draft)
        await sending.processDue()
        do {
            _ = try await sending.cancel(other.id)
            XCTFail("a sent message cannot be cancelled")
        } catch OutboxError.notAllowed(_, let state) {
            XCTAssertEqual(state, .sent)
        }
        await sending.close()
    }

    /// Cancel used to be refused while the send loop happened to be working on the message, so it
    /// failed at random. It now waits for that step and decides on the state the step left.
    func testCancelWaitsForAStepInProgressInsteadOfRefusing() async throws {
        let (message, draft) = try composed()
        let gate = GatedSubmitter(outcome: .notSent(reason: "421 Try again later", permanent: false))
        var configuration = Outbox.Configuration()
        configuration.clock = clock
        configuration.random = { 0 }
        let outbox = try Outbox.open(folder: folder, accounts: FixedDirectory(account: account()),
                                     transport: GatedTransport(submitter: gate), configuration: configuration, faults: .none)
        let entry = try await outbox.enqueue(message, account: accountID, draft: draft)

        let step = Task { await outbox.processDue() }
        var started = gate.startedStream.makeAsyncIterator()
        _ = await started.next()                       // the send is now in progress
        let cancelling = Task { try await outbox.cancel(entry.id) }
        try await Task.sleep(for: .milliseconds(50))   // let Cancel reach the outbox mid-send
        gate.release()                                 // the attempt ends: not sent, may retry
        await step.value

        let cancelled = try await cancelling.value
        XCTAssertEqual(cancelled.entry.draft, draft)
        XCTAssertEqual(cancelled.rawMessage, message.rawMessage)
        let left = await outbox.entries()
        XCTAssertEqual(left, [])
        await outbox.close()
    }
}
