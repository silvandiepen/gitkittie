import Foundation
import MailAccounts
import MailCore
import MailIMAP
import MailMIME
import MailProvider
import MailSMTP
import MailStore
import MailSync
import XCTest

/// Account setup (GKM-010) and the sync coordinator (GKM-011) against the real local mail
/// server and a real store in a temporary folder. Each test has its own synthetic account and
/// checks that its password never reached the log.
final class MailSyncIntegrationTests: XCTestCase {
    private var server: TestMailServer!
    private var user: TestUser!
    private var captured: CapturedLog!
    private var root: URL!
    private var store: MailStore!
    private let account = MailAccountID("sync-test")

    override func setUp() async throws {
        server = try await TestMailServer.require()
        user = try await server.makeUser(function: name)
        captured = CapturedLog()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm-sync-\(UUID().uuidString)", isDirectory: true)
        store = try await MailStore.open(StoreLocations(mailFolder: root.appendingPathComponent("Mail"),
                                                        deviceFolder: root.appendingPathComponent("Support/Mail")))
    }

    override func tearDown() async throws {
        if let user, let captured { captured.assertNoSecret(user.rawPassword) }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Helpers

    private var settings: MailConnectionSettings {
        MailConnectionSettings(
            kind: .imap,
            imap: MailServerSettings(host: "localhost", port: server.imapsPort, security: .implicitTLS, username: user.address),
            smtp: MailServerSettings(host: "localhost", port: server.smtpsPort, security: .implicitTLS, username: user.address))
    }

    private var connections: AccountConnections {
        AccountConnections(trust: server.trust, log: captured.log, connectTimeout: .seconds(5), commandTimeout: .seconds(20))
    }

    private func imap(port: Int? = nil) -> IMAPConnector {
        IMAPConnector(endpoint: ServerEndpoint(host: "localhost", port: port ?? server.imapsPort, security: .implicitTLS, trust: server.trust),
                      credential: user.credential, log: captured.log, commandTimeout: .seconds(20))
    }

    private func coordinator(_ options: SyncOptions) -> SyncCoordinator {
        coordinator(imap(), options)
    }

    private func coordinator(_ connector: IMAPConnector, _ options: SyncOptions) -> SyncCoordinator {
        SyncCoordinator(account: account, connector: connector, store: store, options: options, log: captured.log)
    }

    private static let fast = ReconnectPolicy(maxAttempts: 10, initialDelay: .milliseconds(50), maxDelay: .milliseconds(200), jitter: 0)

    private func message(_ subject: String, minute: Int = 0) -> Data {
        let me = MailAddress(name: "Ada Example", address: user.address)
        return MIMEBuilder(from: me, to: [me], subject: subject, textBody: "Body of \(subject)\n").build()
    }

    /// Appends synthetic messages and returns their bytes, in UID order.
    @discardableResult
    private func append(_ count: Int, to folder: String = "INBOX", prefix: String = "message") async throws -> [Data] {
        var sent: [Data] = []
        try await imap().withSession { session in
            if folder != "INBOX", !(try await session.listFolders().contains { $0.id == folder }) {
                try await session.createFolder(folder)
            }
            for index in 1...count {
                let raw = message("\(prefix) \(index)")
                _ = try await session.append(raw, to: folder, flags: MailProvider.MessageFlags())
                sent.append(raw)
            }
        }
        return sent
    }

    private func storedCount() async throws -> Int { try await store.messageCount() }

    /// Waits for a condition on the real store or server, polling; fails after `timeout`.
    private func waitUntil(_ what: String, timeout: Duration = .seconds(20), _ condition: () async throws -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now + timeout
        while clock.now < end {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: - Account setup

    func testVerificationPassesAndTellsAWrongPasswordAnUnreachableServerAndABadCertificateApart() async throws {
        let verified = try await AccountVerifier(connections: connections).verify(settings, password: user.password)
        XCTAssertEqual(verified, settings)

        let wrong = "wrong-\(UUID().uuidString)"
        do {
            _ = try await AccountVerifier(connections: connections).verify(settings, password: Secret(wrong))
            XCTFail("a wrong password must fail")
        } catch {
            XCTAssertEqual(error, .wrongPassword(.incoming, host: "localhost", kind: .imap))
        }
        captured.assertNoSecret(wrong)

        var unreachable = settings
        unreachable.imap.port = try await Self.closedPort()
        do {
            _ = try await AccountVerifier(connections: connections).verify(unreachable, password: user.password)
            XCTFail("nothing listens there")
        } catch {
            guard case .unreachable(.incoming, "localhost", unreachable.imap.port, _) = error else { return XCTFail("\(error)") }
        }

        let systemTrust = AccountConnections(trust: .system, log: captured.log, connectTimeout: .seconds(5), commandTimeout: .seconds(10))
        do {
            _ = try await AccountVerifier(connections: systemTrust).verify(settings, password: user.password)
            XCTFail("the test CA is not trusted by the system")
        } catch {
            guard case .certificateProblem(.incoming, "localhost", _) = error else { return XCTFail("\(error)") }
        }
    }

    func testVerificationChecksTheOutgoingServerToo() async throws {
        // GreenMail's plain SMTP port offers no STARTTLS: the check must stop there, not sign in.
        var plain = settings
        plain.smtp = MailServerSettings(host: "localhost", port: server.smtpPlainPort, security: .startTLS, username: user.address)
        do {
            _ = try await AccountVerifier(connections: connections).verify(plain, password: user.password)
            XCTFail("no STARTTLS on the outgoing server")
        } catch {
            guard case .notSecure(.outgoing, "localhost", _) = error else { return XCTFail("\(error)") }
        }
    }

    private static func closedPort() async throws -> Int {
        // Bind, read the port, close: nothing listens there afterwards.
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, length) } }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    // MARK: - Import

    func testImportsEveryFolderCompletelyRecentFirstAndOnlyOnce() async throws {
        let inbox = try await append(12)
        try await append(3, to: "Projects", prefix: "project")
        let sync = coordinator(SyncOptions(recentPerFolder: 3, historyPerPass: 4, summaryBatch: 5, bodyBatchMessages: 2,
                                           reconnect: Self.fast))
        try await sync.syncOnce()

        let count = try await storedCount()
        XCTAssertEqual(count, 15)
        let inboxSummaries = try await store.summaries(account: account, mailbox: "INBOX")
        XCTAssertEqual(inboxSummaries.count, 12)
        let projects = try await store.summaries(account: account, mailbox: "Projects")
        XCTAssertEqual(projects.count, 3)
        let folders = try await store.syncedFolders(account: account)
        XCTAssertEqual(folders.first?.name, "INBOX", "the inbox first")
        XCTAssertTrue(folders.allSatisfy(\.historyComplete), "\(folders)")
        XCTAssertEqual(folders.first { $0.name == "INBOX" }?.highestUID, 12)
        let progress = await sync.progress
        XCTAssertEqual(progress.imported, 15)
        XCTAssertEqual(progress.remaining, 0)

        // Every stored original is byte for byte what the server holds.
        for (uid, raw) in zip(1..., inbox) {
            let validity = try XCTUnwrap(folders.first { $0.name == "INBOX" }?.uidValidity)
            let id = try await XCTUnwrapAsync(await store.localID(at: RemoteLocation(mailbox: "INBOX", uidValidity: validity, uid: UInt32(uid)),
                                                                  account: account))
            let original = try await store.originalData(of: id)
            XCTAssertEqual(original, raw)
        }

        // A second sync finds nothing new and writes nothing.
        let again = coordinator(SyncOptions(reconnect: Self.fast))
        try await again.syncOnce()
        let after = try await storedCount()
        XCTAssertEqual(after, 15)
        let secondProgress = await again.progress
        XCTAssertEqual(secondProgress.imported, 0)
    }

    func testHistoryStopsAtTheStorageBudgetButNewMailDoesNot() async throws {
        let sent = try await append(10)
        // Exactly the 3 recent messages (UIDs 10, 9, 8) and two of history (7, 6). GreenMail's
        // RFC822.SIZE is too small (README), so the budget is exact rather than generous.
        let budget = sent[5...9].reduce(0) { $0 + $1.count }
        let sync = coordinator(SyncOptions(recentPerFolder: 3, historyBudgetBytes: Int64(budget),
                                           bodyBatchMessages: 1, reconnect: Self.fast))
        try await sync.syncOnce()
        let count = try await storedCount()
        XCTAssertEqual(count, 5)
        let progress = await sync.progress
        XCTAssertTrue(progress.historyPausedForBudget)
        XCTAssertEqual(progress.remaining, 5)

        try await append(2, prefix: "new")
        try await sync.syncOnce()
        let withNew = try await storedCount()
        XCTAssertEqual(withNew, 7, "new mail is imported even over the budget")
    }

    // MARK: - The history window (GKM-039, MAIL-072)

    /// Appends one message per entry, received the given number of days ago (IMAP APPEND
    /// date-time), and returns the bytes in UID order.
    @discardableResult
    private func append(receivedDaysAgo days: [Int], to folder: String = "INBOX", prefix: String) async throws -> [Data] {
        var sent: [Data] = []
        try await imap().withSession { session in
            if folder != "INBOX", !(try await session.listFolders().contains { $0.id == folder }) {
                try await session.createFolder(folder)
            }
            for (index, age) in days.enumerated() {
                let raw = message("\(prefix) \(index + 1) (\(age) days old)")
                _ = try await session.append(raw, to: folder, flags: MailProvider.MessageFlags(),
                                             receivedAt: Date().addingTimeInterval(-Double(age) * 86_400))
                sent.append(raw)
            }
        }
        return sent
    }

    private func storedSubjects() async throws -> Set<String> {
        Set(try await store.summaries(account: account, limit: 1_000).compactMap(\.subject))
    }

    func testAWindowedFirstSyncTakesOnlyRecentMailNewMailStillComesAndTheRestFollowsWithoutDuplicates() async throws {
        // Older and newer mail interleaved, so the window goes by received date, not by UID. No
        // message is within a day of the window's edge: the server compares days in its own zone.
        let inbox = try await append(receivedDaysAgo: [90, 2, 60, 1, 45, 0, 32], prefix: "inbox")
        let projects = try await append(receivedDaysAgo: [400, 10, 35], to: "Projects", prefix: "project")
        let windowed = SyncOptions(recentPerFolder: 1, historyDays: 30, bodyBatchMessages: 1, reconnect: Self.fast)

        let sync = coordinator(windowed)
        try await sync.syncOnce()
        let recent: Set = ["inbox 2 (2 days old)", "inbox 4 (1 days old)", "inbox 6 (0 days old)", "project 2 (10 days old)"]
        let afterFirst = try await storedSubjects()
        XCTAssertEqual(afterFirst, recent, "only mail received within the last 30 days")
        let progress = await sync.progress
        XCTAssertEqual(progress.olderNotDownloaded, 6)
        XCTAssertEqual(progress.remaining, 0, "the older mail is not counted as still to come")
        XCTAssertEqual(progress.historyDays, 30)
        let folders = try await store.syncedFolders(account: account)
        XCTAssertFalse(folders.contains(where: \.historyComplete), "a folder with mail left out is not complete: \(folders)")
        XCTAssertEqual(folders.first { $0.name == "INBOX" }?.highestUID, 7)

        // A second pass sorted every candidate already: it imports nothing and asks no more.
        let searches = captured.lines.filter { $0.contains("→") && $0.contains("UID SEARCH SINCE") }.count
        XCTAssertEqual(searches, 2, "one search per folder")
        try await sync.syncOnce()
        XCTAssertEqual(captured.lines.filter { $0.contains("→") && $0.contains("UID SEARCH SINCE") }.count, searches)
        let unchanged = try await storedCount()
        XCTAssertEqual(unchanged, 4)

        // New mail always comes in, even when the provider dates it before the window (a message
        // moved in from another folder keeps its received date).
        try await append(receivedDaysAgo: [0, 200], prefix: "new")
        try await sync.syncOnce()
        let withNew = try await storedSubjects()
        XCTAssertEqual(withNew, recent.union(["new 1 (0 days old)", "new 2 (200 days old)"]))

        // Fetching older mail (the window off) stays within the history budget: room for the
        // two newest older inbox messages (UIDs 7 and 5) and no more.
        let imported = try await store.importedBytes(account: account)
        let budget = imported + Int64(inbox[6].count + inbox[4].count)
        let budgeted = coordinator(SyncOptions(recentPerFolder: 1, historyBudgetBytes: budget, bodyBatchMessages: 1,
                                               reconnect: Self.fast))
        try await budgeted.syncOnce()
        let withinBudget = try await storedSubjects()
        XCTAssertEqual(withinBudget.subtracting(withNew), ["inbox 7 (32 days old)", "inbox 5 (45 days old)"])
        let paused = await budgeted.progress
        XCTAssertTrue(paused.historyPausedForBudget)
        XCTAssertEqual(paused.olderNotDownloaded, 0, "without a window nothing is left out by date")
        XCTAssertEqual(paused.remaining, 4)

        // With no limit the rest follows, each message once, byte for byte.
        let everything = coordinator(SyncOptions(reconnect: Self.fast))
        try await everything.syncOnce()
        let count = try await storedCount()
        XCTAssertEqual(count, inbox.count + projects.count + 2)
        let complete = try await store.syncedFolders(account: account)
        XCTAssertTrue(complete.allSatisfy(\.historyComplete), "\(complete)")
        for (folder, sent) in [("INBOX", inbox), ("Projects", projects)] {
            let validity = try XCTUnwrap(complete.first { $0.name == folder }?.uidValidity)
            for (uid, raw) in zip(1..., sent) {
                let id = try await XCTUnwrapAsync(await store.localID(at: RemoteLocation(mailbox: folder, uidValidity: validity, uid: UInt32(uid)),
                                                                      account: account))
                let original = try await store.originalData(of: id)
                XCTAssertEqual(original, raw, "\(folder) \(uid)")
            }
        }
    }

    func testAUIDValidityResetReMapsStoredMessagesWithoutDuplicates() async throws {
        let original = try await append(2, to: "Projects", prefix: "kept")
        // GreenMail 2.1.3 cannot delete a mailbox that a logged-out session still had selected
        // (README): a folder after Projects makes the sync end with that one selected instead.
        try await append(1, to: "Zz Later", prefix: "later")
        try await coordinator(SyncOptions(reconnect: Self.fast)).syncOnce()
        let before = try await store.syncedFolders(account: account).first { $0.name == "Projects" }
        let oldValidity = try XCTUnwrap(before?.uidValidity)
        let firstID = try await XCTUnwrapAsync(await store.localID(at: RemoteLocation(mailbox: "Projects", uidValidity: oldValidity, uid: 1), account: account))

        // Recreate the folder with the same two messages and one new one: a new UIDVALIDITY.
        var newValidity = oldValidity
        for _ in 0..<5 where newValidity == oldValidity {
            try await imap().withSession { session in
                try await session.deleteFolder("Projects")
                try await Task.sleep(for: .milliseconds(1100))
                try await session.createFolder("Projects")
                newValidity = try await session.status(of: "Projects").uidValidity
            }
        }
        XCTAssertNotEqual(newValidity, oldValidity)
        try await imap().withSession { session in
            for raw in original { _ = try await session.append(raw, to: "Projects", flags: MailProvider.MessageFlags()) }
            _ = try await session.append(message("new after the reset"), to: "Projects", flags: MailProvider.MessageFlags())
        }

        try await coordinator(SyncOptions(reconnect: Self.fast)).syncOnce()
        let count = try await storedCount()
        XCTAssertEqual(count, 4, "the two stored messages are re-mapped, not stored again (plus the one in Zz Later)")
        let locations = try await store.remoteLocations(of: firstID, account: account)
        XCTAssertEqual(locations, [RemoteLocation(mailbox: "Projects", uidValidity: newValidity, uid: 1)])
        let folder = try await store.syncedFolders(account: account).first { $0.name == "Projects" }
        XCTAssertEqual(folder?.uidValidity, newValidity)
        XCTAssertEqual(folder?.highestUID, 3)
    }

    func testACutConnectionMidImportReconnectsAndResumesWithoutDuplicates() async throws {
        try await append(20)
        let proxy = try await FaultProxy(targetPort: server.imapsPort)
        defer { Task { await proxy.shutdown() } }
        let sync = coordinator(imap(port: proxy.port), SyncOptions(recentPerFolder: 20, bodyBatchMessages: 2, reconnect: Self.fast))
        let watcher = Task { () -> SyncProgress? in
            var severed = false
            for await progress in sync.updates {
                if !severed, progress.imported >= 6 {
                    severed = true
                    proxy.severAll()
                }
                if case .watching = progress.activity, progress.imported >= 20 { return progress }
            }
            return nil
        }
        await sync.start()
        try await waitUntil("all 20 stored") { try await self.storedCount() == 20 }
        let final = await watcher.value
        await sync.stop()
        XCTAssertNotNil(final)
        XCTAssertEqual(final?.imported, 20, "each message once: the reconnect resumed, it did not start over")
        let count = try await storedCount()
        XCTAssertEqual(count, 20)
        XCTAssertTrue(captured.lines.contains { $0.contains("retrying in") }, "the cut was seen and retried")
    }

    func testStoppingMidImportAndStartingLaterResumesWhereItStopped() async throws {
        try await append(16)
        let first = coordinator(SyncOptions(recentPerFolder: 16, bodyBatchMessages: 2, reconnect: Self.fast))
        let stopper = Task {
            for await progress in first.updates where progress.imported >= 4 {
                await first.stop()
                return
            }
        }
        await first.start()
        await stopper.value
        let partial = try await storedCount()
        XCTAssertLessThan(partial, 16, "stopped part-way")

        let second = coordinator(SyncOptions(reconnect: Self.fast))
        try await second.syncOnce()
        let count = try await storedCount()
        XCTAssertEqual(count, 16)
        let progress = await second.progress
        XCTAssertEqual(progress.imported, 16 - partial, "only what was missing")
    }

    // MARK: - Keeping up

    func testIdleDeliversNewMailAsItArrives() async throws {
        let sync = coordinator(SyncOptions(idleTimeout: .seconds(60), reconnect: Self.fast))
        await sync.start()
        defer { Task { await sync.stop() } }
        try await waitUntil("watching the inbox") {
            if case .watching = await sync.progress.activity { return true }
            return false
        }

        let me = MailAddress(address: user.address)
        let builder = MIMEBuilder(from: me, to: [me], subject: "Arrives while idle", textBody: "Hello.\n")
        let outgoing = OutgoingMessage(messageID: builder.messageID, envelopeFrom: user.address, recipients: builder.recipients,
                                       rawMessage: builder.build())
        guard case .accepted = await connections.smtp(settings, password: user.password).submit(outgoing) else { return XCTFail("send") }

        let clock = ContinuousClock()
        let start = clock.now
        try await waitUntil("the new message stored", timeout: .seconds(15)) { try await self.storedCount() == 1 }
        XCTAssertLessThan(clock.now - start, .seconds(10), "IDLE, not the 60-second poll")
        let summaries = try await store.summaries(account: account, mailbox: "INBOX")
        XCTAssertEqual(summaries.first?.subject, "Arrives while idle")
        await sync.stop()
    }

    func testFlagsAndMovesMadeElsewhereArrive() async throws {
        try await append(2)
        let sync = coordinator(SyncOptions(reconnect: Self.fast))
        try await sync.syncOnce()
        let validity = try await XCTUnwrapAsync(await store.syncedFolders(account: account).first { $0.name == "INBOX" }?.uidValidity)
        let first = try await XCTUnwrapAsync(await store.localID(at: RemoteLocation(mailbox: "INBOX", uidValidity: validity, uid: 1), account: account))
        let second = try await XCTUnwrapAsync(await store.localID(at: RemoteLocation(mailbox: "INBOX", uidValidity: validity, uid: 2), account: account))
        let before = try await store.flags(of: [first], account: account)
        XCTAssertEqual(before[first], MailMessageFlags())

        // Another client reads and flags the first message, and moves the second to Archive.
        try await imap().withSession { session in
            try await session.setFlags(MailProvider.MessageFlags(seen: true, flagged: true, keywords: ["$Label1"]), .add,
                                       on: [RemoteMessageID(folder: "INBOX", uidValidity: validity, uid: 1)])
            try await session.createFolder("Archive")
            _ = try await session.move([RemoteMessageID(folder: "INBOX", uidValidity: validity, uid: 2)], to: "Archive")
        }
        try await sync.syncOnce()

        let after = try await store.flags(of: [first], account: account)
        XCTAssertEqual(after[first], MailMessageFlags(seen: true, flagged: true, keywords: ["$Label1"]))
        let count = try await storedCount()
        XCTAssertEqual(count, 2, "the moved message is the same message, not a new one")
        let moved = try await store.remoteLocations(of: second, account: account)
        XCTAssertEqual(moved.map(\.mailbox), ["Archive"])
        let inbox = try await store.summaries(account: account, mailbox: "INBOX").map(\.id)
        XCTAssertEqual(inbox, [first])
        let archive = try await store.summaries(account: account, mailbox: "Archive").map(\.id)
        XCTAssertEqual(archive, [second])
    }

    func testARefusedPasswordStopsTheSyncAndSaysSo() async throws {
        let wrong = IMAPConnector(endpoint: server.imaps, credential: .password(username: user.address, password: Secret("revoked-\(UUID())")),
                                  log: captured.log)
        let sync = coordinator(wrong, SyncOptions(reconnect: Self.fast))
        await sync.start()
        try await waitUntil("the sign-in failure") {
            if case .signInFailed = await sync.progress.activity { return true }
            return false
        }
        await sync.stop()
    }
}

private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let result = try await value()
    return try XCTUnwrap(result, file: file, line: line)
}
