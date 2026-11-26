import Foundation
import MailCore
import MailIMAP
import MailMIME
import MailProvider
import MailStore
import MailSync
import NIOConcurrencyHelpers
import XCTest

/// The sync's own free-space floor and its other stops on this device (GKM-091, MAIL-123,
/// MAIL-124), against the real local mail server and a real store in a temporary folder. The
/// free space is a value the test sets (``FreeSpaceFloor/available``), so nothing fills this
/// Mac's disk.
final class LocalStopIntegrationTests: XCTestCase {
    private var server: TestMailServer!
    private var user: TestUser!
    private var captured: CapturedLog!
    private var root: URL!
    private var locations: StoreLocations!
    private var store: MailStore!
    private let account = MailAccountID("local-stop-test")

    override func setUp() async throws {
        server = try await TestMailServer.require()
        user = try await server.makeUser(function: name)
        captured = CapturedLog()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm091-sync-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
        store = try await MailStore.open(locations)
    }

    override func tearDown() async throws {
        if let user, let captured { captured.assertNoSecret(user.rawPassword) }
        if let root {
            // A test may leave the mail folder read-only; it must still go.
            try? Self.setPermissions(0o755, under: root.appendingPathComponent("Mail"))
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func imap() -> IMAPConnector {
        IMAPConnector(endpoint: ServerEndpoint(host: "localhost", port: server.imapsPort, security: .implicitTLS, trust: server.trust),
                      credential: user.credential, log: captured.log, commandTimeout: .seconds(20))
    }

    private static let fast = ReconnectPolicy(maxAttempts: 10, initialDelay: .milliseconds(50), maxDelay: .milliseconds(200), jitter: 0)

    private func append(_ count: Int, prefix: String = "message") async throws {
        let me = MailAddress(name: "Ada Example", address: user.address)
        try await imap().withSession { session in
            for index in 1...count {
                let raw = MIMEBuilder(from: me, to: [me], subject: "\(prefix) \(index)", textBody: "Body of \(prefix) \(index)\n").build()
                _ = try await session.append(raw, to: "INBOX", flags: MailProvider.MessageFlags())
            }
        }
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(20), _ condition: () async throws -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now + timeout
        while clock.now < end {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// Files an interrupted write would leave behind: temporary `.partial` files anywhere in the
    /// mail folder, entries in the write journal.
    private func leftovers() throws -> [String] {
        var found: [String] = []
        if let files = FileManager.default.enumerator(atPath: locations.mailFolder.path) {
            for case let path as String in files where path.hasSuffix(".partial") { found.append(path) }
        }
        let journal = locations.deviceFolder.appendingPathComponent("state/journal")
        found += (try? FileManager.default.contentsOfDirectory(atPath: journal.path)) ?? []
        return found
    }

    private static let minimum: Int64 = 2_000_000_000

    /// Sets the permissions of a folder and of every folder inside it.
    private static func setPermissions(_ mode: Int, under folder: URL) throws {
        let fileManager = FileManager.default
        var folders = [folder.path]
        if let paths = fileManager.enumerator(atPath: folder.path) {
            for case let path as String in paths {
                var isDirectory: ObjCBool = false
                let full = folder.appendingPathComponent(path).path
                if fileManager.fileExists(atPath: full, isDirectory: &isDirectory), isDirectory.boolValue { folders.append(full) }
            }
        }
        // Inner folders first when locking, so the walk can still reach them.
        for path in folders.reversed() { try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: path) }
    }

    // MARK: - The floor

    func testThePassStopsBeforeTheNextBatchWhenFreeSpaceDropsUnderTheFloorAndSaysWhy() async throws {
        try await append(20)
        // Plenty of room for the first two batches; then the disk is nearly full. Each batch
        // reads the free space twice: the sync before it downloads, the store before it writes.
        let reads = NIOLockedValueBox(0)
        let free = NIOLockedValueBox<Int64>(40_000_000_000)
        let floor = FreeSpaceFloor(minimumFreeBytes: Self.minimum) { _ in
            let count = reads.withLockedValue { $0 += 1; return $0 }
            if count == 5 { free.withLockedValue { $0 = 1_200_000_000 } }
            return free.withLockedValue { $0 }
        }
        var options = SyncOptions(pipelineStores: false, bodyBatchMessages: 5, reconnect: Self.fast)
        options.freeSpaceFloor = floor
        options.localStopRecheck = .milliseconds(100)
        let sync = SyncCoordinator(account: account, connector: imap(), store: store, options: options, log: captured.log)

        await sync.start()
        try await waitUntil("the pause") {
            if case .pausedForSpace = await sync.progress.activity { return true }
            return false
        }
        // It stopped before the third batch: two batches stored, nothing of the third.
        let stored = try await store.messageCount()
        XCTAssertEqual(stored, 10)
        guard case .pausedForSpace(let freeBytes, let minimumFreeBytes) = await sync.progress.activity else {
            return XCTFail("the pass says it paused for space")
        }
        XCTAssertEqual(freeBytes, 1_200_000_000)
        XCTAssertEqual(minimumFreeBytes, Self.minimum)
        XCTAssertTrue(captured.lines.contains { $0.contains("downloading paused") }, "the log says why")
        XCTAssertEqual(try leftovers(), [], "nothing half written")

        // It stays paused while there is no room, looking again on its own…
        try await Task.sleep(for: .milliseconds(400))
        let stillStored = try await store.messageCount()
        XCTAssertEqual(stillStored, 10)
        if case .pausedForSpace = await sync.progress.activity {} else { XCTFail("still paused") }

        // …and carries on by itself once there is room, without duplicates.
        free.withLockedValue { $0 = 40_000_000_000 }
        try await waitUntil("the rest of the mail") { try await self.store.messageCount() == 20 }
        try await waitUntil("up to date") {
            if case .watching = await sync.progress.activity { return true }
            return false
        }
        await sync.stop()
        let reopened = try await MailStore.open(locations)
        let afterReopen = try await reopened.messageCount()
        XCTAssertEqual(afterReopen, 20)
    }

    func testTheStoreRefusesABatchThatWouldGoUnderTheFloorAndWritesNothingOfIt() async throws {
        try await append(3)
        // The store's own check, without a sync in front of it.
        let fetched = try await imap().withSession { session in
            let listing = try await session.listing(of: "INBOX")
            return try await session.fetchMessages(listing.uids.map {
                RemoteMessageID(folder: "INBOX", uidValidity: listing.status.uidValidity, uid: $0)
            })
        }
        let messages = fetched.map { message in
            SyncedMessage(eml: message.rawMessage,
                          remote: RemoteLocation(mailbox: "INBOX", uidValidity: message.summary.id.uidValidity, uid: message.summary.id.uid),
                          receivedAt: message.summary.internalDate ?? Date(), flags: MailMessageFlags())
        }
        let bytes = messages.reduce(Int64(0)) { $0 + Int64($1.eml.count) }
        // One byte short of room for the batch.
        let floor = FreeSpaceFloor(minimumFreeBytes: Self.minimum) { _ in Self.minimum + bytes - 1 }
        do {
            _ = try await store.storeSynced(messages, account: account, floor: floor)
            XCTFail("the batch would go under the floor")
        } catch MailStoreError.diskNearlyFull(let free, let minimum) {
            XCTAssertEqual(free, Self.minimum + bytes - 1)
            XCTAssertEqual(minimum, Self.minimum)
        }
        let none = try await store.messageCount()
        XCTAssertEqual(none, 0)
        XCTAssertEqual(try leftovers(), [])

        // Exactly enough: stored.
        let roomy = FreeSpaceFloor(minimumFreeBytes: Self.minimum) { _ in Self.minimum + bytes }
        let outcomes = try await store.storeSynced(messages, account: account, floor: roomy)
        XCTAssertEqual(outcomes.count, 3)
    }

    // MARK: - Other stops on this device

    func testAReadOnlyMailFolderStopsTheSyncWithPlainWordsAndItCarriesOnWhenWritable() async throws {
        try await append(2)
        // Every folder in it, so no message folder made at open is left writable.
        try Self.setPermissions(0o555, under: locations.mailFolder)
        var options = SyncOptions(reconnect: Self.fast)
        options.localStopRecheck = .milliseconds(100)
        let sync = SyncCoordinator(account: account, connector: imap(), store: store, options: options, log: captured.log)

        await sync.start()
        try await waitUntil("the stop") {
            if case .cannotStore = await sync.progress.activity { return true }
            return false
        }
        guard case .cannotStore(let problem, _) = await sync.progress.activity else { return XCTFail("a local stop") }
        XCTAssertEqual(problem, .notWritable, "a read-only folder is said as such, not as a network problem")
        let none = try await store.messageCount()
        XCTAssertEqual(none, 0)

        // It never turns into "offline, retrying" while the folder stays read-only.
        try await Task.sleep(for: .milliseconds(400))
        switch await sync.progress.activity {
        case .cannotStore, .connecting, .starting, .importing, .checking: break
        case let other: XCTFail("still a local stop, not \(other)")
        }

        try Self.setPermissions(0o755, under: locations.mailFolder)
        try await waitUntil("the mail once the folder is writable") { try await self.store.messageCount() == 2 }
        await sync.stop()
        // The writes that failed left only their journal entries (outside the mail folder) and no
        // file in it; the store's one recovery path clears them on the next open, as after a
        // crash (AtomicWriter.swift), and nothing is stored twice.
        XCTAssertFalse(try leftovers().contains { $0.hasSuffix(".partial") })
        let reopened = try await MailStore.open(locations)
        let afterReopen = try await reopened.messageCount()
        XCTAssertEqual(afterReopen, 2)
        XCTAssertEqual(try leftovers(), [])
    }
}
