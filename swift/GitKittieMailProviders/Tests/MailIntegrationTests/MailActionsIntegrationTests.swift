import Foundation
@_spi(FaultInjection) import MailIMAP
import MailAccounts
import MailCore
import MailMIME
import MailProvider
import MailStore
import MailSync
import NIOCore
import NIOPosix
import XCTest

/// Everyday actions and the offline action journal (GKM-015) against the real local mail server
/// and a real store: offline actions reach the server once on reconnect, Undo works before and
/// after the server has them, the server's state wins a conflict, and a deleted message's local
/// file stays (MAIL-029). Each test has its own synthetic account.
final class MailActionsIntegrationTests: XCTestCase {
    private var server: TestMailServer!
    private var user: TestUser!
    private var captured: CapturedLog!
    private var root: URL!
    private var store: MailStore!
    private let account = MailAccountID("actions-test")

    override func setUp() async throws {
        server = try await TestMailServer.require()
        user = try await server.makeUser(function: name)
        captured = CapturedLog()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm-actions-\(UUID().uuidString)", isDirectory: true)
        store = try await MailStore.open(StoreLocations(mailFolder: root.appendingPathComponent("Mail"),
                                                        deviceFolder: root.appendingPathComponent("Support/Mail")))
    }

    override func tearDown() async throws {
        if let user, let captured { captured.assertNoSecret(user.rawPassword) }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Helpers

    private func imap(port: Int? = nil) -> IMAPConnector {
        IMAPConnector(endpoint: ServerEndpoint(host: "localhost", port: port ?? server.imapsPort, security: .implicitTLS, trust: server.trust),
                      credential: user.credential, log: captured.log, commandTimeout: .seconds(20))
    }

    private static let fast = ReconnectPolicy(maxAttempts: 3, initialDelay: .milliseconds(50), maxDelay: .milliseconds(200), jitter: 0)

    private func sync() async throws {
        try await SyncCoordinator(account: account, connector: imap(), store: store,
                                  options: SyncOptions(reconnect: Self.fast), log: captured.log).syncOnce()
    }

    /// A replayer that reaches the server.
    private func online(_ connector: (any MailboxConnector)? = nil) -> ActionReplayer {
        ActionReplayer(account: account, connector: connector ?? imap(), store: store, reconnect: Self.fast, log: captured.log)
    }

    /// A replayer whose server cannot be reached: a port nothing listens on.
    private func offline() async throws -> ActionReplayer {
        ActionReplayer(account: account, connector: imap(port: try await Self.closedPort()), store: store, reconnect: Self.fast,
                       log: captured.log)
    }

    private static func closedPort() async throws -> Int {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
        let port = channel.localAddress!.port!
        try await channel.close()
        return port
    }

    @discardableResult
    private func append(_ subjects: [String], to folder: String = "INBOX") async throws -> [Data] {
        var sent: [Data] = []
        try await imap().withSession { session in
            if folder != "INBOX", !(try await session.listFolders().contains { $0.id == folder }) {
                try await session.createFolder(folder)
            }
            let me = MailAddress(name: "Ada Example", address: user.address)
            for subject in subjects {
                let raw = MIMEBuilder(from: me, to: [me], subject: subject, textBody: "Body of \(subject)\n").build()
                _ = try await session.append(raw, to: folder, flags: MailProvider.MessageFlags())
                sent.append(raw)
            }
        }
        return sent
    }

    /// The stored message with this subject.
    private func message(_ subject: String) async throws -> MailMessageID {
        let all = try await store.summaries(account: account, limit: 500)
        return try XCTUnwrap(all.first { $0.subject == subject }?.id, "no stored message \(subject)")
    }

    /// What the server has: subject → flags, per folder.
    private func serverState(_ folder: String) async throws -> [String: MailProvider.MessageFlags] {
        try await imap().withSession { session in
            guard try await session.listFolders().contains(where: { $0.id == folder }) else { return [:] }
            let listing = try await session.listing(of: folder)
            guard !listing.uids.isEmpty else { return [:] }
            let ids = listing.uids.map { RemoteMessageID(folder: folder, uidValidity: listing.status.uidValidity, uid: $0) }
            var result: [String: MailProvider.MessageFlags] = [:]
            for summary in try await session.summaries(of: ids) {
                let subject = summary.subject ?? "?"
                XCTAssertNil(result[subject], "\(subject) is in \(folder) twice")
                result[subject] = summary.flags
            }
            return result
        }
    }

    private func shownIn(_ folder: String) async throws -> [String] {
        try await store.summaries(account: account, mailbox: folder).compactMap(\.subject).sorted()
    }

    // MARK: - Offline, then once on reconnect

    func testActionsTakenOfflineShowAtOnceSurviveASyncAndReachTheServerOnceOnReconnect() async throws {
        try await append(["alpha", "beta", "gamma"])
        try await sync()
        let alpha = try await message("alpha"), beta = try await message("beta"), gamma = try await message("gamma")

        let batch = try await store.perform([
            MailChange(alpha, .setSeen(true)),
            MailChange(beta, .setFlagged(true)),
            MailChange(gamma, .move(from: "INBOX", to: "Archive", createTarget: true)),
        ])
        XCTAssertEqual(batch?.count, 3)

        // Offline: nothing reaches the server, everything stays queued and shows here.
        do {
            try await offline().replayOnce()
            XCTFail("an unreachable server must fail the replay")
        } catch let error as MailProviderError {
            XCTAssertTrue(error.isConnectionProblem)
        }
        var status = try await store.actionStatus(account: account)
        XCTAssertEqual(status.pending, 3)
        XCTAssertEqual(status.pendingMessages, [alpha, beta, gamma])
        let shownInbox = try await shownIn("INBOX")
        XCTAssertEqual(shownInbox, ["alpha", "beta"])
        let shownArchive = try await shownIn("Archive")
        XCTAssertEqual(shownArchive, ["gamma"])
        let alphaFlags = try await store.flags(of: alpha)
        XCTAssertTrue(alphaFlags.seen)

        // A sync pass that reads the server's (old) state does not undo what is queued.
        try await sync()
        let afterSync = try await shownIn("INBOX")
        XCTAssertEqual(afterSync, ["alpha", "beta"])
        let stillSeen = try await store.flags(of: alpha)
        XCTAssertTrue(stillSeen.seen, "a queued change stays shown over the provider's older state")
        let beforeReplay = try await serverState("INBOX")
        XCTAssertEqual(beforeReplay["alpha"]?.seen, false, "nothing reached the server while offline")

        // Reconnect: everything goes, once.
        let report = try await online().replayOnce()
        XCTAssertEqual(report.sent, 3)
        let inbox = try await serverState("INBOX")
        XCTAssertEqual(Set(inbox.keys), ["alpha", "beta"])
        XCTAssertEqual(inbox["alpha"]?.seen, true)
        XCTAssertEqual(inbox["beta"]?.flagged, true)
        let archive = try await serverState("Archive")
        XCTAssertEqual(Set(archive.keys), ["gamma"], "created on demand, one copy")
        status = try await store.actionStatus(account: account)
        XCTAssertEqual(status.pending, 0)

        // A second replay (a reconnect, a relaunch) sends nothing.
        let again = try await online().replayOnce()
        XCTAssertEqual(again, ReplayReport())
        try await sync()
        let count = try await store.messageCount()
        XCTAssertEqual(count, 3, "no message was duplicated or lost")
        let gammaLocations = try await store.remoteLocations(of: gamma, account: account).map(\.mailbox)
        XCTAssertEqual(gammaLocations, ["Archive"])
        let archiveServer = try await serverState("Archive")
        XCTAssertEqual(archiveServer.count, 1)
    }

    // MARK: - Many at once (GKM-071)

    /// A selection of hundreds (every message from one sender) goes to the provider as a few
    /// commands of up to ``ActionReplayer/batchSize`` UIDs, never one per message; read marks
    /// likewise, and the Undo of the whole batch comes back the same way.
    func testHundredsOfMessagesReachTheServerInBatchesAndComeBackInBatches() async throws {
        let count = ActionReplayer.batchSize + 120
        try await append((0..<count).map { "bulk \($0)" })
        try await sync()
        let messages = try await store.summaries(account: account, limit: count + 10)
        XCTAssertEqual(messages.count, count)

        // Read, all at once: one STORE per batch.
        let read = try await store.perform(messages.map { MailChange($0.id, .setSeen(true)) })
        XCTAssertEqual(read?.count, count)
        let marked = try await online().replayOnce()
        XCTAssertEqual(marked.sent, count)
        XCTAssertEqual(marked.commands, 2, "\(count) read marks in two STOREs")

        // Trash, all at once: one MOVE per batch, into a Trash made on first use.
        let trash = try await store.perform(messages.map { MailChange($0.id, .move(from: "INBOX", to: "Trash", createTarget: true)) })
        let trashed = try await online().replayOnce()
        XCTAssertEqual(trashed.sent, count)
        XCTAssertEqual(trashed.commands, 2, "\(count) moves in two MOVEs")
        let inTrash = try await serverState("Trash")
        XCTAssertEqual(inTrash.count, count)
        XCTAssertTrue(inTrash.values.allSatisfy(\.seen))
        let leftInInbox = try await serverState("INBOX")
        XCTAssertEqual(leftInInbox.count, 0)

        // One Undo for the whole batch.
        try await sync()
        _ = try await store.undo(try XCTUnwrap(trash))
        let restored = try await online().replayOnce()
        XCTAssertEqual(restored.sent, count)
        XCTAssertEqual(restored.commands, 2)
        let backInInbox = try await serverState("INBOX")
        XCTAssertEqual(backInInbox.count, count)
        let emptied = try await serverState("Trash")
        XCTAssertEqual(emptied.count, 0)
        let status = try await store.actionStatus(account: account)
        XCTAssertEqual(status.pending, 0)
    }

    func testAReplayStoppedAfterTheServerMovedTheMessageDoesNotMoveItTwice() async throws {
        try await append(["one"])
        try await imap().withSession { try await $0.createFolder("Archive") }
        try await sync()
        let one = try await message("one")
        try await store.perform([MailChange(one, .move(from: "INBOX", to: "Archive"))])

        // The server did the move, then the app stopped before the journal recorded it.
        let location = try await XCTUnwrapAsync(await store.remoteLocations(of: one, account: account).first)
        try await imap().withSession { session in
            _ = try await session.move([RemoteMessageID(folder: "INBOX", uidValidity: location.uidValidity, uid: location.uid)], to: "Archive")
        }

        // Relaunch: the sync sees it left the inbox and arrived in Archive; the replay sends nothing.
        try await sync()
        let report = try await online().replayOnce()
        XCTAssertEqual(report.sent, 0)
        let archive = try await serverState("Archive")
        XCTAssertEqual(Set(archive.keys), ["one"])
        let inbox = try await serverState("INBOX")
        XCTAssertTrue(inbox.isEmpty)
        let shown = try await shownIn("Archive")
        XCTAssertEqual(shown, ["one"])
        let pending = try await store.actionStatus(account: account).pending
        XCTAssertEqual(pending, 0)
    }

    func testMovesWorkWithCopyAndUIDExpungeOnAServerWithoutMove() async throws {
        try await append(["keep", "move me"])
        try await imap().withSession { try await $0.createFolder("Projects") }
        try await sync()
        let moving = try await message("move me")
        try await store.perform([MailChange(moving, .move(from: "INBOX", to: "Projects"))])

        let report = try await online(NoMoveConnector(base: imap())).replayOnce()
        XCTAssertEqual(report.sent, 1)
        let inbox = try await serverState("INBOX")
        XCTAssertEqual(Set(inbox.keys), ["keep"], "only that message left the inbox")
        let projects = try await serverState("Projects")
        XCTAssertEqual(Set(projects.keys), ["move me"])
        let mapped = try await store.remoteLocations(of: moving, account: account).map(\.mailbox)
        XCTAssertEqual(mapped, ["Projects"], "UIDPLUS reported where it went")
    }

    // MARK: - Undo

    func testUndoBeforeReconnectSendsNothingAndUndoAfterPutsItBack() async throws {
        try await append(["a", "b"])
        try await imap().withSession { try await $0.createFolder("Archive") }
        try await sync()
        let a = try await message("a"), b = try await message("b")

        // Undo while still queued: the two cancel out, nothing is sent.
        let archive = try await XCTUnwrapAsync(await store.perform([MailChange(a, .move(from: "INBOX", to: "Archive")),
                                                                    MailChange(a, .setSeen(true))]))
        let undo = try await XCTUnwrapAsync(await store.undo(archive))
        let inboxShown = try await shownIn("INBOX")
        XCTAssertEqual(inboxShown, ["a", "b"])
        let aFlags = try await store.flags(of: a)
        XCTAssertFalse(aFlags.seen)
        var report = try await online().replayOnce()
        XCTAssertEqual(report.sent, 0)
        XCTAssertEqual(report.settled, 4)
        var inbox = try await serverState("INBOX")
        XCTAssertEqual(inbox["a"]?.seen, false)

        // Redo (undo the undo), sent, then undone after the server has it.
        let redo = try await XCTUnwrapAsync(await store.undo(undo))
        report = try await online().replayOnce()
        XCTAssertEqual(report.sent, 2)
        var archived = try await serverState("Archive")
        XCTAssertEqual(archived["a"]?.seen, true)
        try await store.undo(redo)
        let shownBack = try await shownIn("INBOX")
        XCTAssertEqual(shownBack, ["a", "b"], "shown back at once")
        report = try await online().replayOnce()
        XCTAssertEqual(report.sent, 2)
        inbox = try await serverState("INBOX")
        XCTAssertEqual(Set(inbox.keys), ["a", "b"])
        XCTAssertEqual(inbox["a"]?.seen, false)
        archived = try await serverState("Archive")
        XCTAssertTrue(archived.isEmpty)

        // Flags on several messages undo together.
        let flagged = try await XCTUnwrapAsync(await store.perform([MailChange(a, .setFlagged(true)), MailChange(b, .setFlagged(true))]))
        try await online().replayOnce()
        try await store.undo(flagged)
        try await online().replayOnce()
        inbox = try await serverState("INBOX")
        XCTAssertEqual(inbox["a"]?.flagged, false)
        XCTAssertEqual(inbox["b"]?.flagged, false)
        try await sync()
        let count = try await store.messageCount()
        XCTAssertEqual(count, 2)
    }

    func testTrashThenDeletePermanentlyKeepsTheLocalFileAndUndoRestoresOneCopy() async throws {
        let raw = try await append(["doomed", "other"])
        try await imap().withSession { try await $0.createFolder("Trash") }
        try await sync()
        let doomed = try await message("doomed")

        try await store.perform([MailChange(doomed, .move(from: "INBOX", to: "Trash"))])
        try await online().replayOnce()
        try await sync()
        let delete = try await XCTUnwrapAsync(await store.perform([MailChange(doomed, .deletePermanently(from: "Trash"))]))
        let report = try await online().replayOnce()
        XCTAssertEqual(report.sent, 1)
        var trash = try await serverState("Trash")
        XCTAssertTrue(trash.isEmpty, "gone from the server")
        let inbox = try await serverState("INBOX")
        XCTAssertEqual(Set(inbox.keys), ["other"], "nothing else was expunged")

        // MAIL-029: the user's file stays; the message is in no folder but still in All Mail.
        let original = try await store.originalData(of: doomed)
        XCTAssertEqual(original, raw[0])
        try await sync()
        let locations = try await store.remoteLocations(of: doomed, account: account)
        XCTAssertEqual(locations, [])
        let all = try await store.summaries(account: account).map(\.id)
        XCTAssertTrue(all.contains(doomed))

        // Undo puts the stored original back in Trash, once, even when replayed twice.
        try await store.undo(delete)
        let shown = try await shownIn("Trash")
        XCTAssertEqual(shown, ["doomed"])
        try await online().replayOnce()
        try await online().replayOnce()
        trash = try await serverState("Trash")
        XCTAssertEqual(Set(trash.keys), ["doomed"])
        let fetched = try await imap().withSession { session -> Data in
            let listing = try await session.listing(of: "Trash")
            return try await session.fetchMessage(RemoteMessageID(folder: "Trash", uidValidity: listing.status.uidValidity, uid: listing.uids[0])).rawMessage
        }
        XCTAssertEqual(fetched, raw[0], "the original bytes, untouched")
        try await sync()
        let count = try await store.messageCount()
        XCTAssertEqual(count, 2, "the restored copy is the stored message, not a new one")
    }

    // MARK: - Conflicts: the server's state wins

    func testAFlagChangedElsewhereIsNotOverwrittenByAStaleLocalChange() async throws {
        try await append(["shared"])
        try await sync()
        let shared = try await message("shared")
        // Here, offline: flag, then unflag again — the net change is none.
        try await store.perform([MailChange(shared, .setFlagged(true))])
        try await store.perform([MailChange(shared, .setFlagged(false))])
        // Meanwhile another device flags it, and marks it read.
        let location = try await XCTUnwrapAsync(await store.remoteLocations(of: shared, account: account).first)
        try await imap().withSession { session in
            try await session.setFlags(MailProvider.MessageFlags(seen: true, flagged: true), .add,
                                       on: [RemoteMessageID(folder: "INBOX", uidValidity: location.uidValidity, uid: location.uid)])
        }
        let report = try await online().replayOnce()
        XCTAssertEqual(report.sent, 0)
        let server = try await serverState("INBOX")
        XCTAssertEqual(server["shared"]?.flagged, true, "the other device's flag stands")

        // A local change made on the old state, sent after the server changed the same flag:
        // the server wins and the window follows it.
        try await sync()
        try await store.perform([MailChange(shared, .setSeen(false))]) // base: seen
        try await imap().withSession { session in
            try await session.setFlags(MailProvider.MessageFlags(seen: true), .remove,
                                       on: [RemoteMessageID(folder: "INBOX", uidValidity: location.uidValidity, uid: location.uid)])
            try await session.setFlags(MailProvider.MessageFlags(seen: true), .add,
                                       on: [RemoteMessageID(folder: "INBOX", uidValidity: location.uidValidity, uid: location.uid)])
        }
        // Read → unread → read elsewhere is the same value as the base, so this one is sent.
        let sent = try await online().replayOnce()
        XCTAssertEqual(sent.sent, 1)
        let after = try await serverState("INBOX")
        XCTAssertEqual(after["shared"]?.seen, false)
    }

    func testChangesToDifferentFlagsHereAndElsewhereBothSurvive() async throws {
        try await append(["note"])
        try await sync()
        let note = try await message("note")
        try await store.perform([MailChange(note, .setSeen(true))]) // offline, base: unread
        let location = try await XCTUnwrapAsync(await store.remoteLocations(of: note, account: account).first)
        let id = RemoteMessageID(folder: "INBOX", uidValidity: location.uidValidity, uid: location.uid)
        // Elsewhere: flagged and read, then unread again — the server's seen is back at the base,
        // but flagged is new; both devices' intents survive.
        try await imap().withSession { session in
            try await session.setFlags(MailProvider.MessageFlags(flagged: true), .add, on: [id])
        }
        try await sync()
        let shown = try await store.flags(of: note)
        XCTAssertEqual(shown, MessageFlags(seen: true, flagged: true), "the queued read laid over the server's new flag")
        try await online().replayOnce()
        let server = try await serverState("INBOX")
        XCTAssertEqual(server["note"]?.seen, true)
        XCTAssertEqual(server["note"]?.flagged, true)
    }

    func testAMessageMovedOrDeletedElsewhereIsNeverBroughtBackByAQueuedMove() async throws {
        try await append(["moved elsewhere", "deleted elsewhere"])
        try await imap().withSession { session in
            try await session.createFolder("Archive")
            try await session.createFolder("Elsewhere")
        }
        try await sync()
        let moved = try await message("moved elsewhere"), deleted = try await message("deleted elsewhere")
        // Here, offline: archive both, and mark the first read.
        try await store.perform([MailChange(moved, .move(from: "INBOX", to: "Archive")),
                                 MailChange(deleted, .move(from: "INBOX", to: "Archive")),
                                 MailChange(moved, .setSeen(true))])
        // Elsewhere: one is moved to another folder, the other deleted for good.
        let movedAt = try await XCTUnwrapAsync(await store.remoteLocations(of: moved, account: account).first)
        let deletedAt = try await XCTUnwrapAsync(await store.remoteLocations(of: deleted, account: account).first)
        try await imap().withSession { session in
            _ = try await session.move([RemoteMessageID(folder: "INBOX", uidValidity: movedAt.uidValidity, uid: movedAt.uid)], to: "Elsewhere")
            try await session.expunge([RemoteMessageID(folder: "INBOX", uidValidity: deletedAt.uidValidity, uid: deletedAt.uid)])
        }

        // Reconnect: the sync goes first (as in the app), then the replay.
        try await sync()
        let report = try await online().replayOnce()
        XCTAssertEqual(report.sent, 1, "only the read mark is sent, to where the message is now")
        let archive = try await serverState("Archive")
        XCTAssertTrue(archive.isEmpty, "neither message was brought back into Archive")
        let elsewhere = try await serverState("Elsewhere")
        XCTAssertEqual(elsewhere["moved elsewhere"]?.seen, true)
        let shownArchive = try await shownIn("Archive")
        XCTAssertEqual(shownArchive, [])
        let shownElsewhere = try await shownIn("Elsewhere")
        XCTAssertEqual(shownElsewhere, ["moved elsewhere"])
        // MAIL-029: the deleted message's file stays here.
        let kept = try await store.originalData(of: deleted)
        XCTAssertFalse(kept.isEmpty)
        let status = try await store.actionStatus(account: account)
        XCTAssertEqual(status.pending, 0)
        XCTAssertEqual(status.recentlySuperseded, 2)
    }

    // MARK: - The loop

    func testTheReplayLoopRetriesUntilTheServerIsBackThenSendsOnce() async throws {
        try await append(["later"])
        try await sync()
        let later = try await message("later")
        try await store.perform([MailChange(later, .setFlagged(true))])

        // A proxy in front of the server, closed: the loop backs off and keeps the row.
        let proxy = try await FaultProxy(targetPort: server.imapsPort)
        let port = proxy.port
        await proxy.shutdown()
        let replayer = ActionReplayer(account: account, connector: imap(port: port), store: store,
                                      reconnect: ReconnectPolicy(maxAttempts: 1, initialDelay: .milliseconds(100),
                                                                 maxDelay: .milliseconds(300), jitter: 0), log: captured.log)
        await replayer.start()
        try await waitUntil("the replayer to report offline") {
            if case .offline = await replayer.progress.activity { return true }
            return false
        }
        var pending = try await store.actionStatus(account: account).pending
        XCTAssertEqual(pending, 1)
        await replayer.stop()

        // Back online: the loop sends it, once, and goes idle.
        let live = online()
        await live.start()
        try await waitUntil("the change to reach the server") {
            try await self.serverState("INBOX")["later"]?.flagged == true
        }
        try await waitUntil("the journal to empty") { try await self.store.actionStatus(account: self.account).pending == 0 }
        await live.kick()
        try await Task.sleep(for: .milliseconds(300))
        await live.stop()
        pending = try await store.actionStatus(account: account).pending
        XCTAssertEqual(pending, 0)
        let activity = await live.progress.activity
        XCTAssertEqual(activity, .idle)
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(20), _ condition: () async throws -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now + timeout
        while clock.now < end {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("timed out waiting for \(what)")
    }
}

/// The real server, with MOVE switched off in each session, so the COPY + UID EXPUNGE path runs.
private struct NoMoveConnector: MailboxConnector {
    let base: IMAPConnector

    func withSession<Result>(_ body: (any MailboxSession) async throws -> Result) async throws -> Result {
        try await base.withSession { session in
            (session as? IMAPSession)?.disableMoveForTesting()
            return try await body(session)
        }
    }
}

private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let result = try await value()
    return try XCTUnwrap(result, file: file, line: line)
}
