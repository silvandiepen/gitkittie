import Foundation
import MailCompose
import MailCore
import MailMIME
import MailProvider
import NIOConcurrencyHelpers
import XCTest
@testable import MailIMAP
@testable import MailOutbox

/// GKM-014 against the real local server: the real SMTP client, the real IMAP client and real
/// TCP cuts (FaultProxy) at every step of an SMTP session, plus the outbox stopped at every
/// step of its own as a killed process would be. The rule under test: a message reaches each
/// recipient at most once, and exactly once after the person resolves an uncertain send.
final class OutboxIntegrationTests: XCTestCase {
    private var server: TestMailServer!
    private var sender: TestUser!
    private var recipient: TestUser!
    private var captured: CapturedLog!
    private var folder: URL!
    private let clock = TestClock()

    override func setUp() async throws {
        server = try await TestMailServer.require()
        sender = try await server.makeUser(function: name + "from")
        recipient = try await server.makeUser(function: name + "to")
        captured = CapturedLog()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("gkm-outbox-it-\(UUID().uuidString)", isDirectory: true)
        try await imap(sender).withSession { try await $0.createFolder("Sent") }
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        if let captured, let sender {
            captured.assertNoSecret(sender.rawPassword)
        }
    }

    // MARK: - Helpers

    private func imap(_ user: TestUser) -> IMAPConnector {
        IMAPConnector(endpoint: server.imaps, credential: user.credential, log: captured.log, commandTimeout: .seconds(20))
    }

    private var plainSMTP: ServerEndpoint {
        ServerEndpoint(host: "127.0.0.1", port: server.smtpPlainPort, security: .plaintextLoopbackOnly)
    }

    private func settings(smtp: ServerEndpoint, policy: SentCopyPolicy = .append) -> SendingAccountSettings {
        SendingAccountSettings(
            accountID: MailAccountID("acct-it"), identities: [MailAddress(name: "Sender", address: sender.address)],
            smtp: smtp, imap: server.imaps,
            credential: CredentialReference(service: "gitkittie-mail-test", account: sender.address), sentCopy: policy)
    }

    private func open(_ directory: SwitchableDirectory, faults: OutboxFaults = .none) throws -> Outbox {
        var configuration = Outbox.Configuration()
        configuration.clock = clock
        configuration.random = { 0 }
        let credentials = TestCredentials(sender.credential)
        return try Outbox.open(folder: folder, accounts: directory,
                               transport: NetworkOutboxTransport(credentials: credentials, log: captured.log),
                               configuration: configuration, faults: faults, log: captured.log)
    }

    private func compose(_ subject: String, copySelf: Bool = true, bcc: [MailAddress] = []) throws -> (ComposedMessage, ComposeDraft) {
        let draft = ComposeDraft(
            account: MailAccountID("acct-it"), from: MailAddress(name: "Sender", address: sender.address),
            to: [MailAddress(name: "Recipient", address: recipient.address)],
            cc: copySelf ? [MailAddress(address: sender.address)] : [], bcc: bcc,
            subject: subject, body: "Hello from the outbox.\n\nGKM-MIDDLE-OF-THE-BODY\n\n" + String(repeating: "Filler line.\n", count: 200))
        return (try MessageComposer.compose(draft, attachments: []), draft)
    }

    /// How many copies of `messageID` are in `folder` of `user`, after giving delivery a
    /// moment to settle when `expecting` copies have not all arrived yet.
    private func copies(of messageID: String, for user: TestUser, in folder: String = "INBOX", expecting: Int) async throws -> Int {
        try await imap(user).withSession { session in
            var found: [RemoteMessageID] = []
            for _ in 0..<(expecting > 0 ? 40 : 6) {
                found = try await session.search(messageIDHeader: messageID, in: folder)
                if found.count >= expecting && expecting > 0 { break }
                try await Task.sleep(for: .milliseconds(150))
            }
            return found.count
        }
    }

    private func fetch(_ messageID: String, for user: TestUser, in folder: String = "INBOX") async throws -> MIMEMessage {
        try await imap(user).withSession { session in
            let ids = try await session.search(messageIDHeader: messageID, in: folder)
            let id = try XCTUnwrap(ids.first, "<\(messageID)> not in \(folder)")
            return MIMEParser.parse(try await session.fetchMessage(id).rawMessage)
        }
    }

    private func state(_ outbox: Outbox, _ id: OperationID) async throws -> OutboxEntry {
        let entry = await outbox.entry(id)
        return try XCTUnwrap(entry)
    }

    /// Runs the outbox until nothing more is due, as the app's timer would over time.
    private func settle(_ outbox: Outbox, rounds: Int = 4) async {
        for _ in 0..<rounds {
            await outbox.processDue()
            clock.advance(3600)
        }
    }

    // MARK: - The happy path, as iCloud: STARTTLS on submission

    func testSendsOnceOverSTARTTLSWithOneSentCopyAndNoBccAnywhere() async throws {
        let front = try await StartTLSFront(targetPort: server.smtpPlainPort, certificate: server.serverCertificatePEM, key: server.serverKeyPEM)
        defer { Task { await front.shutdown() } }
        let hidden = try await server.makeUser(function: name + "bcc")
        let starttls = ServerEndpoint(host: "localhost", port: front.port, security: .startTLS, trust: server.trust)
        let outbox = try open(SwitchableDirectory(settings(smtp: starttls)))
        let (message, draft) = try compose("happy path", copySelf: false, bcc: [MailAddress(name: "Hidden", address: hidden.address)])

        let entry = try await outbox.enqueue(message, account: MailAccountID("acct-it"), draft: draft)
        await settle(outbox)
        let done = try await state(outbox, entry.id)
        XCTAssertEqual(done.state, .sent)
        XCTAssertEqual(done.sentCopy, .appended)
        XCTAssertEqual(done.attempts, 1)

        let toRecipient = try await copies(of: message.messageID, for: recipient, expecting: 1)
        let toHidden = try await copies(of: message.messageID, for: hidden, expecting: 1)
        let inSent = try await copies(of: message.messageID, for: sender, in: "Sent", expecting: 1)
        XCTAssertEqual([toRecipient, toHidden, inSent], [1, 1, 1])

        // Bcc never in the headers: not in the Sent copy, not at the visible recipient, not at
        // the hidden one.
        for (user, folder) in [(sender!, "Sent"), (recipient!, "INBOX"), (hidden, "INBOX")] {
            let copy = try await fetch(message.messageID, for: user, in: folder)
            XCTAssertNil(copy.headers["Bcc"], "\(folder) of \(user.address)")
            if user.address != hidden.address {
                let headerText = copy.headers.map { "\($0.name): \($0.rawValue)" }.joined(separator: "\n").lowercased()
                XCTAssertFalse(headerText.contains(hidden.address.lowercased()), "the Bcc address leaked into \(folder)")
            }
        }
        await outbox.close()
    }

    // MARK: - A cut at every SMTP step

    func testACutAtEverySMTPStepNeverDeliversTwice() async throws {
        enum Expect { case retried, uncertainNotThere, uncertainThere, sent, either }
        let steps: [(String, FaultProxy.Mode?, Expect)] = [
            ("connection refused", nil, .retried),
            ("before the greeting", .cutBeforeGreeting, .retried),
            ("at EHLO", .cutWhenClientSends("EHLO"), .retried),
            ("at AUTH", .cutWhenClientSends("AUTH"), .retried),
            ("at MAIL FROM", .cutWhenClientSends("MAIL FROM"), .retried),
            ("at RCPT TO", .cutWhenClientSends("RCPT TO"), .retried),
            ("at DATA", .cutWhenClientSends("DATA\r\n"), .retried),
            ("in the middle of the message", .cutWhenClientSends("GKM-MIDDLE-OF-THE-BODY"), .either),
            ("at the end-of-data marker", .cutWhenClientSends("\r\n.\r\n"), .uncertainNotThere),
            ("after the server accepted", .cutAfterEndOfData, .uncertainThere),
            ("at QUIT", .cutWhenClientSends("QUIT"), .sent),
        ]

        for (index, (step, mode, expect)) in steps.enumerated() {
            try? FileManager.default.removeItem(at: folder)
            let proxy = try await FaultProxy(targetPort: server.smtpPlainPort, mode: mode ?? .relay)
            if mode == nil { await proxy.shutdown() }
            let viaProxy = ServerEndpoint(host: "127.0.0.1", port: proxy.port, security: .plaintextLoopbackOnly)
            let directory = SwitchableDirectory(settings(smtp: viaProxy))
            let outbox = try open(directory)
            let (message, draft) = try compose("cut number \(index)") // never a step name: the proxy watches for those
            let entry = try await outbox.enqueue(message, account: MailAccountID("acct-it"), draft: draft)

            await outbox.processDue()
            let afterCut = try await state(outbox, entry.id)
            switch expect {
            case .retried:
                XCTAssertEqual(afterCut.state, .queued, step)
                XCTAssertNotNil(afterCut.lastError, step)
            case .uncertainNotThere:
                XCTAssertEqual(afterCut.state, .uncertain, step)
            case .uncertainThere:
                // Uncertain at the SMTP level, then found in the inbox by reconciliation.
                XCTAssertEqual(afterCut.state, .sent, "\(step): \(afterCut.history)")
                XCTAssertTrue(afterCut.history.contains { $0.state == .uncertain }, step)
            case .sent:
                XCTAssertEqual(afterCut.state, .sent, "\(step): \(afterCut.history)")
            case .either:
                XCTAssertTrue([.queued, .uncertain].contains(afterCut.state), "\(step): \(afterCut.state)")
            }

            // The network comes back. The outbox runs for hours of (test) time.
            await directory.update(settings(smtp: plainSMTP))
            await settle(outbox)
            var current = try await state(outbox, entry.id)
            if current.state == .uncertain {
                // Not found anywhere: the outbox never resent it on its own.
                let nothing = try await copies(of: message.messageID, for: recipient, expecting: 0)
                XCTAssertEqual(nothing, 0, "\(step): an uncertain send must not be resent automatically")
                XCTAssertEqual(current.attempts, 1, step)
                // The person decides to send it again; the outbox checks once more first.
                try await outbox.sendAgain(entry.id)
                await settle(outbox)
                current = try await state(outbox, entry.id)
            }
            XCTAssertEqual(current.state, .sent, step)
            XCTAssertTrue(current.isComplete, step)

            let atRecipient = try await copies(of: message.messageID, for: recipient, expecting: 1)
            let atSender = try await copies(of: message.messageID, for: sender, expecting: 1)
            let inSent = try await copies(of: message.messageID, for: sender, in: "Sent", expecting: 1)
            XCTAssertEqual(atRecipient, 1, "\(step): delivered exactly once")
            XCTAssertEqual(atSender, 1, "\(step): delivered exactly once to the Cc")
            XCTAssertEqual(inSent, 1, "\(step): one Sent copy")

            await outbox.close()
            await proxy.shutdown()
        }
    }

    /// The P0 on a provider whose Sent folder cannot show the message (no copy to self, no
    /// provider copy): the server took it, the reply was lost, and nothing can prove it. The
    /// outbox keeps it uncertain and visible for as long as it runs, and never sends again.
    func testLostReplyWithNothingToReconcileStaysUncertainAndIsNeverResent() async throws {
        let proxy = try await FaultProxy(targetPort: server.smtpPlainPort, mode: .cutAfterEndOfData)
        defer { Task { await proxy.shutdown() } }
        let directory = SwitchableDirectory(settings(smtp: ServerEndpoint(host: "127.0.0.1", port: proxy.port, security: .plaintextLoopbackOnly)))
        let outbox = try open(directory)
        let (message, draft) = try compose("lost reply, nothing to find", copySelf: false)
        let entry = try await outbox.enqueue(message, account: MailAccountID("acct-it"), draft: draft)

        await outbox.processDue()
        await directory.update(settings(smtp: plainSMTP))
        await settle(outbox, rounds: 8)

        let current = try await state(outbox, entry.id)
        XCTAssertEqual(current.state, .uncertain)
        XCTAssertEqual(current.attempts, 1)
        XCTAssertNotNil(current.lastReconciledAt)
        let delivered = try await copies(of: message.messageID, for: recipient, expecting: 1)
        XCTAssertEqual(delivered, 1, "the server had it once, and only once")
        await outbox.close()
    }

    // MARK: - The process stopped at every outbox step

    func testAStopBeforeAnythingWentOutComesBackUncertainAndSendsOnceAfterTheDecision() async throws {
        let directory = SwitchableDirectory(settings(smtp: plainSMTP))
        let dying = try open(directory, faults: OutboxFaults { if $0 == .markedSending { throw SimulatedStop() } })
        let (message, draft) = try compose("stop after marking sending")
        let entry = try await dying.enqueue(message, account: MailAccountID("acct-it"), draft: draft)
        await dying.processDue()
        await dying.close()

        let relaunched = try open(directory)
        await settle(relaunched)
        var current = try await state(relaunched, entry.id)
        XCTAssertEqual(current.state, .uncertain, "nothing proves it was not sent")
        let none = try await copies(of: message.messageID, for: recipient, expecting: 0)
        XCTAssertEqual(none, 0)

        try await relaunched.sendAgain(entry.id)
        await settle(relaunched)
        current = try await state(relaunched, entry.id)
        XCTAssertEqual(current.state, .sent)
        let once = try await copies(of: message.messageID, for: recipient, expecting: 1)
        let inSent = try await copies(of: message.messageID, for: sender, in: "Sent", expecting: 1)
        XCTAssertEqual([once, inSent], [1, 1])
        await relaunched.close()
    }

    func testAStopAfterAcceptanceIsReconciledNotResent() async throws {
        let directory = SwitchableDirectory(settings(smtp: plainSMTP))
        let dying = try open(directory, faults: OutboxFaults {
            if case .submitted(.accepted(_)) = $0 { throw SimulatedStop() }
        })
        let (message, draft) = try compose("stop after acceptance")
        let entry = try await dying.enqueue(message, account: MailAccountID("acct-it"), draft: draft)
        await dying.processDue()
        await dying.close()

        let relaunched = try open(directory)
        await settle(relaunched)
        let current = try await state(relaunched, entry.id)
        XCTAssertEqual(current.state, .sent, "found in the inbox by Message-ID")
        XCTAssertEqual(current.attempts, 1)
        let once = try await copies(of: message.messageID, for: recipient, expecting: 1)
        let inSent = try await copies(of: message.messageID, for: sender, in: "Sent", expecting: 1)
        XCTAssertEqual([once, inSent], [1, 1])
        await relaunched.close()
    }

    func testAStopBeforeOrAfterTheSentAppendLeavesOneSentCopy() async throws {
        for stop in [OutboxStep.markedSent, .appendedSentCopy] {
            try? FileManager.default.removeItem(at: folder)
            let directory = SwitchableDirectory(settings(smtp: plainSMTP))
            let dying = try open(directory, faults: OutboxFaults { if $0 == stop { throw SimulatedStop() } })
            let (message, draft) = try compose("stop at \(stop)")
            let entry = try await dying.enqueue(message, account: MailAccountID("acct-it"), draft: draft)
            await dying.processDue()
            await dying.close()

            let relaunched = try open(directory)
            await settle(relaunched)
            let current = try await state(relaunched, entry.id)
            XCTAssertEqual(current.state, .sent, "\(stop)")
            XCTAssertEqual(current.sentCopy, stop == .markedSent ? .appended : .alreadyThere, "\(stop)")
            let once = try await copies(of: message.messageID, for: recipient, expecting: 1)
            let inSent = try await copies(of: message.messageID, for: sender, in: "Sent", expecting: 1)
            XCTAssertEqual([once, inSent], [1, 1], "\(stop)")
            await relaunched.close()
        }
    }

    // MARK: - Sent copy policies

    func testDetectWaitsForTheProviderThenAppendsOnce() async throws {
        let outbox = try open(SwitchableDirectory(settings(smtp: plainSMTP, policy: .detect)))
        let (message, draft) = try compose("detect", copySelf: false)
        let entry = try await outbox.enqueue(message, account: MailAccountID("acct-it"), draft: draft)
        await outbox.processDue()
        var current = try await state(outbox, entry.id)
        XCTAssertEqual(current.state, .sent)
        XCTAssertEqual(current.sentCopy, .pending, "waiting for the provider's own copy")
        let none = try await copies(of: message.messageID, for: sender, in: "Sent", expecting: 0)
        XCTAssertEqual(none, 0)

        clock.advance(121)
        await outbox.processDue()
        current = try await state(outbox, entry.id)
        XCTAssertEqual(current.sentCopy, .appended)
        await outbox.processDue()
        let one = try await copies(of: message.messageID, for: sender, in: "Sent", expecting: 1)
        XCTAssertEqual(one, 1)
        await outbox.close()
    }

    func testAPermanentRefusalFailsWithoutRetrying() async throws {
        var wrong = settings(smtp: plainSMTP)
        wrong.identities = [MailAddress(address: sender.address)]
        let outbox = try Outbox.open(
            folder: folder, accounts: SwitchableDirectory(wrong),
            transport: NetworkOutboxTransport(credentials: TestCredentials(.password(username: sender.address, password: Secret("wrong-password"))),
                                              log: captured.log),
            configuration: { var c = Outbox.Configuration(); c.clock = clock; c.random = { 0 }; return c }(), log: captured.log)
        let (message, draft) = try compose("wrong password", copySelf: false)
        let entry = try await outbox.enqueue(message, account: MailAccountID("acct-it"), draft: draft)
        await settle(outbox)
        let current = try await state(outbox, entry.id)
        XCTAssertEqual(current.state, .failed)
        XCTAssertEqual(current.attempts, 1, "a refused password is not retried by itself")
        XCTAssertTrue(current.lastError?.contains("authentication") == true, current.lastError ?? "")
        let none = try await copies(of: message.messageID, for: recipient, expecting: 0)
        XCTAssertEqual(none, 0)
        await outbox.close()
    }
}

// MARK: - Test configuration (real values, not stand-ins for behaviour)

final class TestClock: OutboxClock, Sendable {
    private let current = NIOLockedValueBox(Date())
    func now() -> Date { current.withLockedValue { $0 } }
    func advance(_ seconds: TimeInterval) { current.withLockedValue { $0 = $0.addingTimeInterval(seconds) } }
}

/// The account settings, changeable mid-test the way a network coming back changes the route.
actor SwitchableDirectory: SendingAccountDirectory {
    private var settings: SendingAccountSettings
    init(_ settings: SendingAccountSettings) { self.settings = settings }
    func update(_ settings: SendingAccountSettings) { self.settings = settings }
    func sendingAccount(_ id: MailAccountID) async throws -> (any SendingAccount)? {
        settings.accountID == id ? settings : nil
    }
}

/// The test user's credential, as the Keychain would hand it over.
struct TestCredentials: CredentialProvider {
    let credential: MailCredential
    init(_ credential: MailCredential) { self.credential = credential }
    func credential(for reference: CredentialReference) async throws -> MailCredential { credential }
}
