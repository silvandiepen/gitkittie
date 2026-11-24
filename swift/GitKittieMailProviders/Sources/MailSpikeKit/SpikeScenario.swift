import Foundation
import MailCore
import MailMIME
import MailProvider
@_spi(FaultInjection) import MailSMTP
@_spi(FaultInjection) import MailIMAP

/// The GKM-004 end-to-end spike: one scripted run against a real account that exercises every
/// Roadmap phase 0 item (TLS, folders, incremental fetch, flags, attachments, send and Sent
/// reconciliation, moves, an uncertain send, a UIDVALIDITY reset, reconnects, IDLE, malformed
/// mail). The `gkmail-spike` command runs it against iCloud or the local test server; an
/// integration test runs it against the local server.
///
/// It only touches what it creates: its own messages (sent to the account itself) and one
/// folder named `GitKittieMail-Spike-…`, which it deletes at the end.
public struct SpikeConfiguration: Sendable {
    public var address: String
    public var imap: ServerEndpoint
    public var smtp: ServerEndpoint
    public var credential: MailCredential
    /// How long to wait for a sent message to show up (iCloud can take a while).
    public var arrivalTimeout: Duration

    public init(address: String, imap: ServerEndpoint, smtp: ServerEndpoint, credential: MailCredential,
                arrivalTimeout: Duration = .seconds(120)) {
        self.address = address
        self.imap = imap
        self.smtp = smtp
        self.credential = credential
        self.arrivalTimeout = arrivalTimeout
    }
}

public struct SpikeStep: Sendable {
    public var name: String
    public var passed: Bool
    public var notes: [String]
}

public struct SpikeReport: Sendable {
    public var steps: [SpikeStep]
    public var passed: Bool { !steps.isEmpty && steps.allSatisfy(\.passed) }
}

public struct SpikeFailure: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

public final class SpikeScenario {
    let configuration: SpikeConfiguration
    let log: MailLog
    private(set) var steps: [SpikeStep] = []
    private var notes: [String] = []
    private let runID = String(UUID().uuidString.prefix(8)).lowercased()
    /// Every Message-ID this run sent, so clean-up finds them wherever they ended up.
    private var sentMessageIDs: [String] = []

    public init(configuration: SpikeConfiguration, log: MailLog) {
        self.configuration = configuration
        self.log = log.scrubbing([configuration.credential.secret])
    }

    var connector: IMAPConnector {
        IMAPConnector(endpoint: configuration.imap, credential: configuration.credential, log: log)
    }

    func submitter(_ fault: SMTPFaultInjection? = nil) -> SMTPSubmitter {
        var submitter = SMTPSubmitter(endpoint: configuration.smtp, credential: configuration.credential, log: log)
        submitter.faultInjection = fault
        return submitter
    }

    func note(_ text: String) {
        notes.append(text)
        log.info("spike", text)
    }

    func step(_ name: String, _ body: () async throws -> Void) async -> Bool {
        notes = []
        log.info("spike", "── \(name)")
        do {
            try await body()
            steps.append(SpikeStep(name: name, passed: true, notes: notes))
            return true
        } catch {
            notes.append("FAILED: \(error)")
            log.error("spike", "\(name) FAILED: \(error)")
            steps.append(SpikeStep(name: name, passed: false, notes: notes))
            return false
        }
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw SpikeFailure(message()) }
    }

    func makeMessage(subject: String, attachment: OutgoingAttachment? = nil) -> (MIMEBuilder, OutgoingMessage) {
        let me = MailAddress(name: "GitKittie Mail Spike", address: configuration.address)
        let builder = MIMEBuilder(
            from: me, to: [me],
            subject: "[gkm-spike \(runID)] \(subject) — Ünïcode ✓",
            textBody: "Synthetic test message from the GitKittie Mail spike (GKM-004).\nRun \(runID).\n",
            attachments: attachment.map { [$0] } ?? []
        )
        sentMessageIDs.append(builder.messageID)
        let outgoing = OutgoingMessage(messageID: builder.messageID, envelopeFrom: configuration.address,
                                       recipients: builder.recipients, rawMessage: builder.build())
        return (builder, outgoing)
    }

    /// Polls until `messageID` shows up in `folder`.
    func waitForMessage(_ messageID: String, in folder: String, session: any MailboxSession) async throws -> [RemoteMessageID] {
        let clock = ContinuousClock()
        let deadline = clock.now + configuration.arrivalTimeout
        while true {
            let found = try await session.search(messageIDHeader: messageID, in: folder)
            if !found.isEmpty { return found }
            guard clock.now < deadline else { throw SpikeFailure("<\(messageID)> did not arrive in \(folder) within \(configuration.arrivalTimeout)") }
            try await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: - The run

    public func run() async -> SpikeReport {
        let spikeFolder = "GitKittieMail-Spike-\(runID)"
        var inbox = "INBOX"
        var sentFolder: String?
        var spikeIDs: [RemoteMessageID] = []
        var attachmentData = Data()

        // 1. TLS, login, folders.
        let connected = await step("Connect over TLS and list folders") {
            try await connector.withSession { session in
                let folders = try await session.listFolders()
                note("\(folders.count) folders; roles: " + folders.compactMap { f in f.role.map { "\($0.rawValue)=\(f.id)" } }.joined(separator: ", "))
                note("capabilities: push=\(session.capabilities.push) move=\(session.capabilities.atomicMove) uidplus=\(session.capabilities.reportsNewIDs) condstore=\(session.capabilities.changeTracking)")
                inbox = folders.first { $0.role == .inbox }?.id ?? "INBOX"
                sentFolder = folders.first { $0.role == .sent }?.id
                if sentFolder == nil {
                    try await session.createFolder("Sent")
                    sentFolder = "Sent"
                    note("no Sent folder; created one (local test server)")
                }
                try await session.createFolder(spikeFolder)
                note("created \(spikeFolder)")
            }
        }
        guard connected, let sent = sentFolder else { return SpikeReport(steps: steps) }

        // 2. Incremental fetch from "now", then send, then find it.
        var cursor: SyncCursor?
        _ = await step("Incremental fetch baseline") {
            try await connector.withSession { session in
                let status = try await session.status(of: inbox)
                // Start from the current end of the inbox: incremental logic without downloading
                // someone's whole mailbox.
                cursor = SyncCursor(folder: inbox, uidValidity: status.uidValidity,
                                    highestFetchedUID: (status.uidNext ?? 1) - 1)
                note("\(inbox): \(status.messageCount) messages, UIDVALIDITY \(status.uidValidity), UIDNEXT \(status.uidNext.map(String.init) ?? "?")")
                let changes = try await session.changes(in: inbox, since: cursor)
                try expect(!changes.isReset, "a fresh cursor must not reset")
                try expect(changes.newMessages.isEmpty, "nothing should be new yet (got \(changes.newMessages.count))")
            }
        }

        let attachment = OutgoingAttachment(
            filename: "spike-attachment ü.bin", mimeType: "application/octet-stream",
            data: Data((0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        )
        attachmentData = attachment.data
        let (_, firstMessage) = makeMessage(subject: "send and receive", attachment: attachment)

        _ = await step("Send via SMTP and reconcile with Sent") {
            let outcome = await submitter().submit(firstMessage)
            guard case .accepted = outcome else { throw SpikeFailure("submission: \(outcome)") }
            note("SMTP accepted <\(firstMessage.messageID)>")
            try await connector.withSession { session in
                let arrived = try await waitForMessage(firstMessage.messageID, in: inbox, session: session)
                note("arrived in \(inbox) as \(arrived.map(\.description).joined(separator: ", "))")
                // Does the provider keep a Sent copy itself? Only then is appending one wrong.
                try await Task.sleep(for: .seconds(1))
                let providerCopy = try await session.search(messageIDHeader: firstMessage.messageID, in: sent)
                let followUp = SubmissionFollowUp.after(outcome, providerSavesSentCopy: !providerCopy.isEmpty)
                note("provider Sent copy: \(providerCopy.isEmpty ? "none" : "yes") → \(followUp)")
                if case .markSent(appendSentCopy: true) = followUp {
                    let appended = try await session.append(firstMessage.rawMessage, to: sent, flags: MessageFlags(seen: true))
                    note("appended Sent copy\(appended.map { " as \($0)" } ?? "")")
                }
                let inSent = try await session.search(messageIDHeader: firstMessage.messageID, in: sent)
                try expect(inSent.count == 1, "exactly one Sent copy expected, found \(inSent.count)")
                spikeIDs += inSent
            }
        }

        _ = await step("Incremental fetch picks up exactly the new message; attachment intact") {
            try await connector.withSession { session in
                let changes = try await session.changes(in: inbox, since: cursor)
                try expect(!changes.isReset, "unexpected reset")
                let mine = changes.newMessages.filter { MessageIDs.normalize($0.messageIDHeader ?? "") == firstMessage.messageID }
                try expect(mine.count == 1, "the sent message should be new exactly once (found \(mine.count) of \(changes.newMessages.count))")
                cursor = changes.nextCursor
                let again = try await session.changes(in: inbox, since: cursor)
                try expect(again.newMessages.allSatisfy { $0.id.uid > changes.nextCursor.highestFetchedUID }, "cursor did not advance")
                let fetched = try await session.fetchMessage(mine[0].id)
                let parsed = MIMEParser.parse(fetched.rawMessage)
                try expect(parsed.messageID == firstMessage.messageID, "Message-ID changed in transit")
                try expect(parsed.attachments.first?.body == attachmentData, "attachment bytes differ")
                try expect(parsed.attachments.first?.filename == "spike-attachment ü.bin", "attachment name differs: \(parsed.attachments.first?.filename ?? "nil")")
                note("fetched \(fetched.rawMessage.count) bytes; attachment of \(attachmentData.count) bytes intact; subject \"\(parsed.subject ?? "")\"")
                spikeIDs.append(mine[0].id)
            }
        }

        _ = await step("Flags: set and clear") {
            try await connector.withSession { session in
                guard let id = spikeIDs.last else { throw SpikeFailure("no message from the previous step") }
                try await session.setFlags(MessageFlags(seen: true, flagged: true), .add, on: [id])
                var flags = try await session.flags(in: id.folder)[id]
                try expect(flags?.seen == true && flags?.flagged == true, "flags not set: \(String(describing: flags))")
                try await session.setFlags(MessageFlags(flagged: true), .remove, on: [id])
                flags = try await session.flags(in: id.folder)[id]
                try expect(flags?.seen == true && flags?.flagged == false, "flag not cleared: \(String(describing: flags))")
                note("\\Seen and \\Flagged set, \\Flagged cleared")
            }
        }

        _ = await step("Move to another folder") {
            try await connector.withSession { session in
                guard let id = spikeIDs.popLast() else { throw SpikeFailure("no message to move") }
                let mapping = try await session.move([id], to: spikeFolder)
                let stillThere = try await session.search(messageIDHeader: firstMessage.messageID, in: inbox)
                try expect(stillThere.isEmpty, "message still in \(inbox) after the move")
                let moved = try await session.search(messageIDHeader: firstMessage.messageID, in: spikeFolder)
                try expect(moved.count == 1, "message not found in \(spikeFolder)")
                if let newID = mapping[id] {
                    try expect(newID == moved[0], "UIDPLUS mapping \(newID) differs from search \(moved[0])")
                    note("moved; server reported the new id \(newID) (UIDPLUS)")
                } else {
                    note("moved; server did not report the new id, found it by Message-ID")
                }
            }
        }

        _ = await step("Uncertain send: connection lost after the server accepted") {
            let (_, message) = makeMessage(subject: "uncertain send")
            let outcome = await submitter(.loseFinalReply).submit(message)
            guard case .uncertain = outcome else { throw SpikeFailure("expected .uncertain, got \(outcome)") }
            let followUp = SubmissionFollowUp.after(outcome, providerSavesSentCopy: false)
            try expect(followUp == .reconcile, "uncertain must lead to reconciliation, got \(followUp)")
            note("outcome uncertain → \(followUp); no resend")
            try await connector.withSession { session in
                _ = try await waitForMessage(message.messageID, in: inbox, session: session)
                let result = try await SendReconciler.reconcile(messageID: message.messageID, in: [inbox, sent], session: session)
                guard case .found(let ids) = result else { throw SpikeFailure("reconciliation found nothing") }
                let delivered = ids.filter { $0.folder == inbox }
                try expect(delivered.count == 1, "expected exactly one delivered copy, found \(delivered.count)")
                note("reconciled: delivered exactly once; marked sent without resending")
                _ = try await session.move(delivered, to: spikeFolder)
            }
        }

        _ = await step("UIDVALIDITY change forces a resync; stale UIDs are refused") {
            try await connector.withSession { session in
                let folder = "\(spikeFolder)-uv"
                try await session.createFolder(folder)
                let (_, a) = makeMessage(subject: "uidvalidity a")
                _ = try await session.append(a.rawMessage, to: folder, flags: MessageFlags())
                let first = try await session.changes(in: folder, since: nil)
                try expect(first.isReset && first.newMessages.count == 1, "initial sync of the new folder")
                let staleID = first.newMessages[0].id
                var status = try await session.status(of: folder)
                var attempts = 0
                repeat {
                    // Servers derive UIDVALIDITY from the clock; recreate until it differs.
                    try await session.deleteFolder(folder)
                    try await Task.sleep(for: .milliseconds(1100))
                    try await session.createFolder(folder)
                    status = try await session.status(of: folder)
                    attempts += 1
                } while status.uidValidity == first.nextCursor.uidValidity && attempts < 5
                try expect(status.uidValidity != first.nextCursor.uidValidity, "could not provoke a UIDVALIDITY change")
                let (_, b) = makeMessage(subject: "uidvalidity b")
                _ = try await session.append(b.rawMessage, to: folder, flags: MessageFlags())
                let after = try await session.changes(in: folder, since: first.nextCursor)
                try expect(after.isReset, "UIDVALIDITY change not detected")
                try expect(after.newMessages.count == 1, "resync should list the folder's one message")
                do {
                    _ = try await session.fetchMessage(staleID)
                    throw SpikeFailure("a UID from before the reset was accepted")
                } catch MailProviderError.messageNotFound {
                    note("UIDVALIDITY \(first.nextCursor.uidValidity) → \(status.uidValidity): reset detected, stale UID refused")
                }
                try await session.deleteFolder(folder)
            }
        }

        _ = await step("IDLE: wakes on new mail, times out when quiet") {
            try await connector.withSession { session in
                let quiet = try await session.waitForChanges(in: spikeFolder, timeout: .seconds(2))
                try expect(quiet == .timedOut, "IDLE on a quiet folder should time out, got \(quiet)")
                let (_, message) = makeMessage(subject: "idle wake-up")
                let sender = submitter()
                let send = Task { await sender.submit(message) }
                let event = try await session.waitForChanges(in: inbox, timeout: configuration.arrivalTimeout)
                let outcome = await send.value
                try expect(event == .changed, "IDLE did not report the new message")
                guard case .accepted = outcome else { throw SpikeFailure("send during IDLE: \(outcome)") }
                note("IDLE (\(session.capabilities.push ? "server push" : "NOOP polling")): quiet → timedOut, new mail → changed")
                let ids = try await waitForMessage(message.messageID, in: inbox, session: session)
                _ = try await session.move(ids, to: spikeFolder)
            }
        }

        _ = await step("Reconnect after the connection drops") {
            var attempts = 0
            let policy = ReconnectPolicy(maxAttempts: 3, initialDelay: .milliseconds(200), maxDelay: .seconds(1))
            let count = try await policy.retrying(log: log) {
                attempts += 1
                return try await connector.withIMAPSession { session in
                    if attempts == 1 {
                        session.dropConnectionForTesting()
                    }
                    return try await session.listFolders().count
                }
            }
            try expect(attempts == 2, "expected one failed attempt and one reconnect, got \(attempts)")
            note("first session lost its connection; reconnected and listed \(count) folders")
        }

        _ = await step("Malformed message survives the round trip") {
            try await connector.withSession { session in
                let raw = Data("""
                From: =?UTF-8?B?broken <spike@example.com>\r
                Subject: =?x-unknown?Q?=FF=FE?=\r
                Content-Type: multipart/mixed; boundary="never-closed"\r
                Message-ID: <malformed-\(runID)@example.com>\r
                \r
                --never-closed\r
                Content-Type: text/plain; charset=bogus\r
                Content-Transfer-Encoding: base64\r
                \r
                !!!not base64!!!\r
                """.utf8)
                let id = try await session.append(raw, to: spikeFolder, flags: MessageFlags())
                let found = try await session.search(messageIDHeader: "malformed-\(runID)@example.com", in: spikeFolder)
                guard let target = id ?? found.first else { throw SpikeFailure("appended message not found") }
                let fetched = try await session.fetchMessage(target)
                try expect(fetched.rawMessage == raw, "server changed the malformed bytes")
                let parsed = MIMEParser.parse(fetched.rawMessage)
                note("stored byte-identical; parser problems: \(parsed.problems.joined(separator: "; "))")
                try expect(!parsed.problems.isEmpty, "the parser should report the missing boundary")
            }
        }

        _ = await step("Clean up") {
            try await connector.withSession { session in
                var moved = 0
                for messageID in sentMessageIDs {
                    for folder in [inbox, sent] {
                        let ids = try await session.search(messageIDHeader: messageID, in: folder)
                        if !ids.isEmpty {
                            _ = try await session.move(ids, to: spikeFolder)
                            moved += ids.count
                        }
                    }
                }
                try await session.deleteFolder(spikeFolder)
                note("moved \(moved) leftover spike messages into \(spikeFolder) and deleted it")
            }
        }
        return SpikeReport(steps: steps)
    }
}
