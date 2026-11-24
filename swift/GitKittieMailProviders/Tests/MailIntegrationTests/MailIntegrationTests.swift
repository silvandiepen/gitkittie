import Foundation
import MailCore
import MailMIME
import MailProvider
import MailSpikeKit
import XCTest
@_spi(FaultInjection) import MailIMAP
@_spi(FaultInjection) import MailSMTP

/// End-to-end tests against the real local mail server (scripts/test-mail-server.sh).
/// Every test gets its own synthetic account and checks that its password never reached a log.
final class MailIntegrationTests: XCTestCase {
    private var server: TestMailServer!
    private var user: TestUser!
    private var captured: CapturedLog!

    override func setUp() async throws {
        server = try await TestMailServer.require()
        user = try await server.makeUser(function: name)
        captured = CapturedLog()
    }

    override func tearDown() async throws {
        if let user, let captured {
            captured.assertNoSecret(user.rawPassword)
            let plainToken = Data("\0\(user.address)\0\(user.rawPassword)".utf8).base64EncodedString()
            XCTAssertFalse(captured.lines.joined().contains(plainToken), "AUTH PLAIN token found in the log")
        }
    }

    private var imap: IMAPConnector {
        IMAPConnector(endpoint: server.imaps, credential: user.credential, log: captured.log, commandTimeout: .seconds(20))
    }

    private func smtp(_ endpoint: ServerEndpoint? = nil) -> SMTPSubmitter {
        SMTPSubmitter(endpoint: endpoint ?? server.smtps, credential: user.credential, log: captured.log,
                      replyTimeout: .seconds(20), finalReplyTimeout: .seconds(30))
    }

    private func message(_ subject: String, attachment: OutgoingAttachment? = nil) -> OutgoingMessage {
        let me = MailAddress(name: "Test Ünïcode", address: user.address)
        let builder = MIMEBuilder(from: me, to: [me], subject: subject, textBody: "Body of \(subject)\n",
                                  attachments: attachment.map { [$0] } ?? [])
        return OutgoingMessage(messageID: builder.messageID, envelopeFrom: user.address,
                               recipients: builder.recipients, rawMessage: builder.build())
    }

    private func waitFor(_ messageID: String, in folder: String = "INBOX", count: Int = 1,
                         session: any MailboxSession) async throws -> [RemoteMessageID] {
        for _ in 0..<50 {
            let found = try await session.search(messageIDHeader: messageID, in: folder)
            if found.count >= count { return found }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("<\(messageID)> did not arrive in \(folder)")
        return []
    }

    /// Delivery prepends trace fields (Return-Path, Received, RFC 5321 4.4); everything we sent
    /// must follow unchanged.
    /// GreenMail also keeps the CRLF before the end-of-data dot as part of the terminator, so
    /// the final line break may be missing.
    static func isDelivered(_ sent: Data, as delivered: Data) -> Bool {
        let crlf = Data("\r\n".utf8)
        let sent = sent.suffix(2) == crlf ? sent.dropLast(2) : sent
        let delivered = delivered.suffix(2) == crlf ? delivered.dropLast(2) : delivered
        guard delivered.count >= sent.count, delivered.suffix(sent.count) == sent else { return false }
        let added = String(decoding: delivered.prefix(delivered.count - sent.count), as: UTF8.self)
        let fields = MIMEParser.parse(Data((added + "\r\n").utf8)).headers.map { $0.name.lowercased() }
        return fields.allSatisfy { ["received", "return-path", "delivered-to"].contains($0) }
    }

    // MARK: - Connection and security

    func testConnectsOverTLSListsFoldersAndReportsCapabilities() async throws {
        try await imap.withSession { session in
            let folders = try await session.listFolders()
            XCTAssertEqual(folders.first { $0.role == .inbox }?.id, "INBOX")
            XCTAssertTrue(session.capabilities.push)
            XCTAssertTrue(session.capabilities.atomicMove)
            XCTAssertTrue(session.capabilities.reportsNewIDs)
        }
    }

    func testCertificateFromAnUntrustedCAIsRejected() async throws {
        let untrusted = ServerEndpoint(host: "localhost", port: server.imapsPort, security: .implicitTLS, trust: .system)
        do {
            try await IMAPConnector(endpoint: untrusted, credential: user.credential, log: captured.log).withSession { _ in }
            XCTFail("a certificate the system does not trust must be refused")
        } catch let error as MailProviderError {
            guard case .connectionFailed(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("TLS"), reason)
        }
        let smtpOutcome = await smtp(ServerEndpoint(host: "localhost", port: server.smtpsPort, security: .implicitTLS, trust: .system))
            .submit(message("never sent"))
        guard case .notSent = smtpOutcome else { return XCTFail("\(smtpOutcome)") }
    }

    func testWrongPasswordFailsAsAuthenticationAndIsNotLogged() async throws {
        let wrong = "wrong-\(UUID().uuidString)"
        let connector = IMAPConnector(endpoint: server.imaps,
                                      credential: .password(username: user.address, password: Secret(wrong)), log: captured.log)
        do {
            try await connector.withSession { _ in }
            XCTFail("login with a wrong password must fail")
        } catch let error as MailProviderError {
            guard case .authenticationFailed = error else { return XCTFail("\(error)") }
        }
        let outcome = await SMTPSubmitter(endpoint: server.smtps, credential: .password(username: user.address, password: Secret(wrong)),
                                          log: captured.log).submit(message("bad auth"))
        guard case .notSent(_, let permanent) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(permanent)
        captured.assertNoSecret(wrong)
    }

    func testSTARTTLSSubmissionAsICloudUsesIt() async throws {
        let front = try await StartTLSFront(targetPort: server.smtpPlainPort, certificate: server.serverCertificatePEM, key: server.serverKeyPEM)
        defer { Task { await front.shutdown() } }
        let endpoint = ServerEndpoint(host: "localhost", port: front.port, security: .startTLS, trust: server.trust)
        let sent = message("via STARTTLS")
        let outcome = await smtp(endpoint).submit(sent)
        guard case .accepted = outcome else { return XCTFail("\(outcome)") }
        try await imap.withSession { session in
            let found = try await waitFor(sent.messageID, session: session)
            XCTAssertEqual(found.count, 1)
        }
        XCTAssertTrue(captured.lines.contains { $0.contains("TLS started") })
    }

    func testServerWithoutSTARTTLSIsRefusedNotUsedInTheClear() async throws {
        // GreenMail's port 3025 offers no STARTTLS: what a downgrade attacker would present.
        let endpoint = ServerEndpoint(host: "localhost", port: server.smtpPlainPort, security: .startTLS, trust: server.trust)
        let sent = message("must not be sent")
        let outcome = await smtp(endpoint).submit(sent)
        guard case .notSent(let reason, let permanent) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(permanent)
        XCTAssertTrue(reason.contains("STARTTLS"), reason)
        XCTAssertFalse(captured.lines.contains { $0.contains("→ AUTH") }, "no credentials before TLS")
        try await imap.withSession { session in
            let found = try await session.search(messageIDHeader: sent.messageID, in: "INBOX")
            XCTAssertTrue(found.isEmpty)
        }
    }

    // MARK: - Mail flow

    func testSendFetchIncrementallyWithAttachmentFlagsAndMove() async throws {
        let attachmentBytes = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let first = message("first", attachment: OutgoingAttachment(filename: "Résumé (final).pdf", mimeType: "application/pdf", data: attachmentBytes))
        guard case .accepted = await smtp().submit(first) else { return XCTFail("first send") }

        try await imap.withSession { session in
            _ = try await waitFor(first.messageID, session: session)
            let initial = try await session.changes(in: "INBOX", since: nil)
            XCTAssertTrue(initial.isReset, "a first sync is a full sync")
            XCTAssertEqual(initial.newMessages.map(\.messageIDHeader).map { MessageIDs.normalize($0 ?? "") }, [first.messageID])

            let nothing = try await session.changes(in: "INBOX", since: initial.nextCursor)
            XCTAssertFalse(nothing.isReset)
            XCTAssertEqual(nothing.newMessages.count, 0, "UID n:* must not return the last message again")

            let second = message("second")
            guard case .accepted = await smtp().submit(second) else { return XCTFail("second send") }
            _ = try await waitFor(second.messageID, session: session)
            let next = try await session.changes(in: "INBOX", since: initial.nextCursor)
            XCTAssertEqual(next.newMessages.map { MessageIDs.normalize($0.messageIDHeader ?? "") }, [second.messageID])
            XCTAssertGreaterThan(next.nextCursor.highestFetchedUID, initial.nextCursor.highestFetchedUID)

            // Body and attachment, byte for byte.
            let fetched = try await session.fetchMessage(initial.newMessages[0].id)
            XCTAssertTrue(Self.isDelivered(first.rawMessage, as: fetched.rawMessage), "the server must hand back the bytes we sent")
            let parsed = MIMEParser.parse(fetched.rawMessage)
            XCTAssertEqual(parsed.attachments.first?.filename, "Résumé (final).pdf")
            XCTAssertEqual(parsed.attachments.first?.body, attachmentBytes)
            XCTAssertEqual(parsed.subject, "first")

            // Flags.
            let id = initial.newMessages[0].id
            try await session.setFlags(MessageFlags(seen: true, flagged: true, keywords: ["$GKMTest"]), .add, on: [id])
            var flags = try await session.flags(in: "INBOX")
            XCTAssertEqual(flags[id], MessageFlags(seen: true, flagged: true, keywords: ["$GKMTest"]))
            try await session.setFlags(MessageFlags(flagged: true), .remove, on: [id])
            flags = try await session.flags(in: "INBOX")
            XCTAssertEqual(flags[id]?.flagged, false)
            XCTAssertEqual(flags[id]?.seen, true)

            // Move, with the new id reported by the server.
            try await session.createFolder("Archive")
            let moved = try await session.move([id], to: "Archive")
            let newID = try XCTUnwrap(moved[id])
            XCTAssertEqual(newID.folder, "Archive")
            let leftInInbox = try await session.search(messageIDHeader: first.messageID, in: "INBOX")
            XCTAssertEqual(leftInInbox, [])
            let movedMessage = try await session.fetchMessage(newID)
            XCTAssertEqual(movedMessage.rawMessage, fetched.rawMessage, "a move keeps the bytes")
            let archiveFlags = try await session.flags(in: "Archive")
            XCTAssertEqual(archiveFlags[newID]?.seen, true, "flags travel with the message")
            do {
                _ = try await session.fetchMessage(id)
                XCTFail("the old id must not resolve after the move")
            } catch MailProviderError.messageNotFound {}
        }
    }

    func testSentCopyIsAppendedAndFoundByMessageID() async throws {
        let sent = message("sent copy")
        let outcome = await smtp().submit(sent)
        XCTAssertEqual(SubmissionFollowUp.after(outcome, providerSavesSentCopy: false), .markSent(appendSentCopy: true))
        try await imap.withSession { session in
            try await session.createFolder("Sent")
            let appended = try await session.append(sent.rawMessage, to: "Sent", flags: MessageFlags(seen: true))
            XCTAssertNotNil(appended, "UIDPLUS reports the new id")
            let result = try await SendReconciler.reconcile(messageID: sent.messageID, in: ["Sent"], session: session)
            XCTAssertEqual(result, .found([try XCTUnwrap(appended)]))
            // A Message-ID that merely contains another as a substring is not a match.
            let prefix = String(sent.messageID.dropLast(4))
            let substringMatches = try await session.search(messageIDHeader: prefix, in: "Sent")
            XCTAssertEqual(substringMatches, [])
        }
    }

    // MARK: - Uncertain sends

    func testLostReplyAfterAcceptanceIsUncertainAndReconcilesWithoutResend() async throws {
        var submitter = smtp()
        submitter.faultInjection = .loseFinalReply
        let sent = message("uncertain over TLS")
        let outcome = await submitter.submit(sent)
        guard case .uncertain = outcome else { return XCTFail("expected uncertain, got \(outcome)") }
        XCTAssertEqual(SubmissionFollowUp.after(outcome, providerSavesSentCopy: true), .reconcile)
        try await imap.withSession { session in
            _ = try await waitFor(sent.messageID, session: session)
            let result = try await SendReconciler.reconcile(messageID: sent.messageID, in: ["INBOX"], session: session)
            guard case .found(let ids) = result else { return XCTFail("\(result)") }
            XCTAssertEqual(ids.count, 1, "delivered exactly once; nothing was resent")
        }
    }

    func testNetworkCutAfterEndOfDataIsUncertain() async throws {
        let proxy = try await FaultProxy(targetPort: server.smtpPlainPort, mode: .cutAfterEndOfData)
        defer { Task { await proxy.shutdown() } }
        let endpoint = ServerEndpoint(host: "127.0.0.1", port: proxy.port, security: .plaintextLoopbackOnly)
        let sent = message("uncertain via a real cut")
        let outcome = await smtp(endpoint).submit(sent)
        guard case .uncertain = outcome else { return XCTFail("expected uncertain, got \(outcome)") }
        try await imap.withSession { session in
            let ids = try await waitFor(sent.messageID, session: session)
            XCTAssertEqual(ids.count, 1, "the server took it once; the client must not send it again")
        }
    }

    func testNetworkCutBeforeDataIsNotSentAndSafeToRetry() async throws {
        let proxy = try await FaultProxy(targetPort: server.smtpPlainPort)
        let endpoint = ServerEndpoint(host: "127.0.0.1", port: proxy.port, security: .plaintextLoopbackOnly)
        await proxy.shutdown()
        let outcome = await smtp(endpoint).submit(message("never connected"))
        guard case .notSent(_, let permanent) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(permanent, "a connection failure is temporary")
    }

    // MARK: - Resets, reconnects, push

    func testUIDValidityChangeForcesFullResyncAndRefusesStaleUIDs() async throws {
        try await imap.withSession { session in
            try await session.createFolder("Projects")
            let a = message("a"), b = message("b")
            _ = try await session.append(a.rawMessage, to: "Projects", flags: MessageFlags())
            _ = try await session.append(b.rawMessage, to: "Projects", flags: MessageFlags())
            let synced = try await session.changes(in: "Projects", since: nil)
            XCTAssertEqual(synced.newMessages.count, 2)

            var status = try await session.status(of: "Projects")
            for _ in 0..<5 where status.uidValidity == synced.nextCursor.uidValidity {
                try await session.deleteFolder("Projects")
                try await Task.sleep(for: .milliseconds(1100))
                try await session.createFolder("Projects")
                status = try await session.status(of: "Projects")
            }
            XCTAssertNotEqual(status.uidValidity, synced.nextCursor.uidValidity)
            let c = message("c")
            _ = try await session.append(c.rawMessage, to: "Projects", flags: MessageFlags())

            let after = try await session.changes(in: "Projects", since: synced.nextCursor)
            XCTAssertTrue(after.isReset)
            XCTAssertEqual(after.newMessages.map { MessageIDs.normalize($0.messageIDHeader ?? "") }, [c.messageID])
            XCTAssertEqual(after.newMessages.first?.id.uid, 1, "UID 1 again, but a different message")
            do {
                _ = try await session.fetchMessage(synced.newMessages[0].id)
                XCTFail("UID 1 from the old UIDVALIDITY must not fetch the new message")
            } catch MailProviderError.messageNotFound {}
            do {
                try await session.setFlags(MessageFlags(seen: true), .add, on: [synced.newMessages[0].id])
                XCTFail("flags must not be applied through a stale UID")
            } catch MailProviderError.messageNotFound {}
        }
    }

    func testReconnectsAfterTheNetworkDrops() async throws {
        let proxy = try await FaultProxy(targetPort: server.imapsPort)
        defer { Task { await proxy.shutdown() } }
        // TLS end to end through the proxy: it only moves bytes.
        let connector = IMAPConnector(
            endpoint: ServerEndpoint(host: "localhost", port: proxy.port, security: .implicitTLS, trust: server.trust),
            credential: user.credential, log: captured.log, commandTimeout: .seconds(10)
        )
        let policy = ReconnectPolicy(maxAttempts: 3, initialDelay: .milliseconds(50), maxDelay: .milliseconds(100))
        var attempts = 0
        let folders = try await policy.run(connector, log: captured.log) { session in
            attempts += 1
            if attempts == 1 {
                _ = try await session.listFolders()
                proxy.severAll()
            }
            return try await session.listFolders()
        }
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(folders.contains { $0.id == "INBOX" })
        XCTAssertTrue(captured.lines.contains { $0.contains("reconnect") })
    }

    func testIdleWakesOnNewMailAndTimesOutWhenQuiet() async throws {
        try await imap.withSession { session in
            let quiet = try await session.waitForChanges(in: "INBOX", timeout: .seconds(1))
            XCTAssertEqual(quiet, .timedOut)

            let sent = message("wake up")
            let submitter = smtp()
            let send = Task { await submitter.submit(sent) }
            let clock = ContinuousClock()
            let start = clock.now
            let event = try await session.waitForChanges(in: "INBOX", timeout: .seconds(20))
            XCTAssertEqual(event, .changed)
            XCTAssertLessThan(clock.now - start, .seconds(15), "IDLE should report new mail promptly")
            guard case .accepted = await send.value else { return XCTFail("send") }
            // The session is still usable after IDLE.
            let changes = try await session.changes(in: "INBOX", since: nil)
            XCTAssertEqual(changes.newMessages.count, 1)
        }
    }

    func testMalformedMessageIsStoredAndParsedDefensively() async throws {
        let raw = Data("From: =?UTF-8?B?broken <x@example.com>\r\nSubject: =?bogus?Q?=FF?=\r\nMessage-ID: <malformed@example.com>\r\nContent-Type: multipart/mixed\r\n\r\n--nothing\r\nContent-Transfer-Encoding: base64\r\n\r\n%%%\r\n".utf8)
        try await imap.withSession { session in
            let id = try await XCTUnwrapAsync(try await session.append(raw, to: "INBOX", flags: MessageFlags()))
            let fetched = try await session.fetchMessage(id)
            XCTAssertEqual(fetched.rawMessage, raw)
            let parsed = MIMEParser.parse(fetched.rawMessage)
            XCTAssertFalse(parsed.problems.isEmpty)
            XCTAssertEqual(parsed.messageID, "malformed@example.com")
        }
    }

    // MARK: - The GKM-004 spike, exactly as it runs against iCloud

    func testSpikeScenarioPassesAgainstTheLocalServer() async throws {
        let configuration = SpikeConfiguration(
            address: user.address, imap: server.imaps, smtp: server.smtps, credential: user.credential,
            arrivalTimeout: .seconds(20)
        )
        let report = await SpikeScenario(configuration: configuration, log: captured.log).run()
        for step in report.steps {
            if step.name == "Clean up" {
                // GreenMail 2.1.3 defect, not ours: LOGOUT does not deselect, so deleting a
                // mailbox an earlier session had selected kills the deleting connection
                // (NullPointerException in ImapHandler.forceConnectionClose). Reproduced by hand
                // with openssl; real servers do not do this. The per-test account is discarded.
                XCTAssertTrue(step.passed || step.notes.contains { $0.contains("connection lost") },
                              "Clean up failed for another reason: \(step.notes)")
                continue
            }
            XCTAssertTrue(step.passed, "\(step.name): \(step.notes.joined(separator: " | "))")
        }
        XCTAssertEqual(report.steps.count, 12)
    }
}

private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let result = try await value()
    return try XCTUnwrap(result, file: file, line: line)
}
