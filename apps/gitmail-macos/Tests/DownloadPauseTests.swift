import Synchronization
import XCTest
import MailAccounts
import MailCore
import MailProvider
import MailStore
import MailSync

/// Downloading pauses when the Mac's disk is nearly full and carries on by itself (MAIL-106,
/// GKM-090), through the app model against a real store in a temporary folder. The free space
/// is a value the test sets (`AccountServices.freeSpace`), so nothing depends on this Mac's disk;
/// the sync is the real one against the local test mail server
/// (`swift/GitKittieMailProviders/scripts/test-mail-server.sh start`; those tests skip without it).
@MainActor
final class DownloadPauseTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var credentials: KeychainCredentialStore!
    /// What the disk that holds the mail folder has free, as the sync sees it. The sync's floor
    /// reads it from its own actor (GKM-091), so it is behind a lock.
    private let disk = Disk()
    private var free: Int64 {
        get { disk.free }
        set { disk.free = newValue }
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm090-pause-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
        defaultsSuite = "gkm090-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        credentials = KeychainCredentialStore(service: "app.hakobs.gitmail.tests.\(UUID().uuidString)", useDataProtectionKeychain: false)
    }

    override func tearDown() async throws {
        if let locations { try? Self.setPermissions(0o755, under: locations.mailFolder) }
        if let locations, let store = try? await MailStore.open(locations) {
            for account in (try? await store.accounts()) ?? [] { try? credentials.delete(for: account.id) }
        }
        defaults?.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }

    private func services(trust: TrustPolicy = .system) -> AccountServices {
        let connections = AccountConnections(trust: trust, connectTimeout: .seconds(5), commandTimeout: .seconds(15))
        var services = AccountServices(
            credentials: credentials, connections: connections, verifier: AccountVerifier(connections: connections),
            syncOptions: SyncOptions(idleTimeout: .seconds(30),
                                     reconnect: ReconnectPolicy(initialDelay: .milliseconds(50), maxDelay: .milliseconds(200), jitter: 0)),
            defaults: defaults)
        services.freeSpace = { [disk] _ in disk.free }
        // The watch looks often, so "by itself" is seen within the test's time.
        services.freeSpaceCheckInterval = .milliseconds(100)
        return services
    }

    private func draft(_ server: LocalMailServer, _ user: LocalMailServer.User) -> AccountDraft {
        var draft = AccountDraft()
        draft.provider = .other
        draft.address = user.address
        draft.password = user.password
        draft.imapHost = "localhost"
        draft.imapPort = server.imapsPort
        draft.smtpHost = "localhost"
        draft.smtpPort = server.smtpsPort
        draft.smtpSecurity = .implicitTLS
        draft.name = "Test"
        return draft
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

    private static func gigabytes(_ value: Double) -> Int64 { Int64(value * 1_000_000_000) }

    func testTheMacPausesBelowTwoGigabytesAndSaysSoInWords() async throws {
        XCTAssertEqual(AccountServices.live.minimumFreeBytes, 2_000_000_000, "Sil: pause below 2 GB on the Mac (MAIL-106)")
        free = Self.gigabytes(0.9)
        var services = services()
        services.freeSpaceCheckInterval = .seconds(3600) // only the checks this test makes
        let model = AppModel(locations: locations, services: services)
        await model.open()
        XCTAssertEqual(model.phase, .ready)
        let pause = try XCTUnwrap(model.sync.downloadPause, "under 2 GB free the sync pauses when it starts")
        let amount = (0.9).formatted(.number.precision(.fractionLength(1)))
        XCTAssertEqual(pause.text, "Downloading paused: only \(amount) GB free on this Mac. It carries on by itself when there is room.")
        XCTAssertEqual(pause.minimumFreeBytes, 2_000_000_000)

        // Just over the minimum: no pause.
        free = Self.gigabytes(2.1)
        await model.sync.reviewFreeSpace()
        XCTAssertNil(model.sync.downloadPause)

        // A disk whose free space can't be read is not reported as full.
        model.sync.services.freeSpace = { _ in nil }
        await model.sync.reviewFreeSpace()
        XCTAssertNil(model.sync.downloadPause)
    }

    func testDownloadingPausesWhenTheDiskFillsAndCarriesOnByItselfWhenThereIsRoom() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        try await server.append(["Before the pause"], for: user)

        // The disk is nearly full when the account is added: it is saved and its actions start,
        // but nothing downloads, and the sidebar says why.
        free = Self.gigabytes(1.2)
        let model = AppModel(locations: locations, services: services(trust: server.trust))
        await model.open()
        let account = try await model.addAccount(draft(server, user))
        XCTAssertNotNil(model.sync.downloadPause)
        XCTAssertTrue(model.sync.isSyncing(account.id))
        XCTAssertTrue(model.sync.isPausedForSpace(account.id))
        XCTAssertFalse(model.sync.isRunning)
        XCTAssertEqual(model.syncStatus(account.id), DownloadPause.shortText)
        XCTAssertEqual(model.totalCount, 0)

        // Space comes back: the watch notices without being asked and the mail comes in.
        free = Self.gigabytes(40)
        try await waitUntil("the sync to carry on by itself") { model.sync.isRunning }
        XCTAssertNil(model.sync.downloadPause)
        XCTAssertFalse(model.sync.isPausedForSpace(account.id))
        try await waitUntil("the mail from before the pause") {
            ((try? await model.mailStore?.messageCount()) ?? 0) == 1
        }

        // The disk fills while it runs: downloading stops by itself and says so; the account
        // stays set up.
        free = Self.gigabytes(0.5)
        try await waitUntil("the sync to pause") { !model.sync.isRunning }
        XCTAssertNotNil(model.sync.downloadPause)
        XCTAssertTrue(model.sync.isPausedForSpace(account.id))
        XCTAssertEqual(model.accounts.map(\.id), [account.id])

        // Mail that arrives meanwhile waits at the provider…
        try await server.append(["While the disk was full"], for: user)
        try await Task.sleep(for: .milliseconds(500))
        let stored = try await XCTUnwrap(model.mailStore).messageCount()
        XCTAssertEqual(stored, 1, "nothing downloads while paused")

        // …and comes in once there is room, with no restart.
        free = Self.gigabytes(40)
        try await waitUntil("the mail that arrived during the pause") {
            ((try? await model.mailStore?.messageCount()) ?? 0) == 2
        }
        XCTAssertNil(model.sync.downloadPause)
        await model.sync.stopAll()
    }

    // MARK: The sync's own floor and other stops on this Mac (GKM-091)

    func testTheSyncsOwnFloorStopsABatchAndShowsAsThePause() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        try await server.append(["Larger than the room left"], for: user)

        // Just over the minimum: the model's own check finds room, but the message would take
        // the disk under it, so the sync's floor stops before downloading it.
        free = DownloadPause.macMinimumFreeBytes + 100
        let model = AppModel(locations: locations, services: services(trust: server.trust))
        await model.open()
        let account = try await model.addAccount(draft(server, user))
        try await waitUntil("the floor's pause") { model.syncStatus(account.id) == DownloadPause.shortText }
        let pause = try XCTUnwrap(model.sync.downloadPause, "shown as the MAIL-106 pause, not as offline")
        XCTAssertEqual(pause.minimumFreeBytes, DownloadPause.macMinimumFreeBytes, "one minimum for the pause and the floor")
        XCTAssertTrue(model.sync.isPausedForSpace(account.id))
        let stored = try await XCTUnwrap(model.mailStore).messageCount()
        XCTAssertEqual(stored, 0)

        // Room again: it carries on by itself.
        free = Self.gigabytes(40)
        try await waitUntil("the mail") { ((try? await model.mailStore?.messageCount()) ?? 0) == 1 }
        try await waitUntil("the pause to clear") { model.sync.downloadPause == nil }
        XCTAssertFalse(model.sync.isPausedForSpace(account.id))
        await model.sync.stopAll()
    }

    func testAReadOnlyMailFolderIsSaidInWordsAndTheSyncCarriesOnWhenItIsWritable() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        free = Self.gigabytes(40)
        let model = AppModel(locations: locations, services: services(trust: server.trust))
        await model.open()
        let account = try await model.addAccount(draft(server, user))
        try await waitUntil("the first sync") { model.syncStatus(account.id) == "Up to date" }

        try Self.setPermissions(0o555, under: locations.mailFolder)
        defer { try? Self.setPermissions(0o755, under: locations.mailFolder) }
        try await server.append(["While the folder is read-only"], for: user)
        try await waitUntil("the stop") { model.syncStatus(account.id)?.hasPrefix("Can’t save mail") == true }
        XCTAssertEqual(model.syncStatus(account.id),
                       "Can’t save mail · the mail folder is read-only\nGive yourself permission to write to it again and it carries on by itself.")
        XCTAssertNil(model.sync.downloadPause, "not a lack of space")

        try Self.setPermissions(0o755, under: locations.mailFolder)
        try await waitUntil("the mail") { ((try? await model.mailStore?.messageCount()) ?? 0) == 1 }
        try await waitUntil("up to date again") { model.syncStatus(account.id) == "Up to date" }
        await model.sync.stopAll()
    }

    func testEveryStopOnThisMacSaysWhatHappenedAndWhatToDo() {
        func status(_ problem: LocalStoreProblem) -> [String?] {
            var progress = SyncProgress()
            progress.activity = .cannotStore(problem, reason: "technical")
            return [SyncStatusText.line(progress), SyncStatusText.advice(progress)]
        }
        XCTAssertEqual(status(.diskFull), ["Can’t save mail · this Mac is out of space", "Free some space and it carries on by itself."])
        XCTAssertEqual(status(.folderUnavailable), [
            "Can’t save mail · the mail folder can’t be found",
            "Reconnect the disk it is on, or choose the folder again in Settings ▸ Storage. It carries on by itself when it’s back.",
        ])
        XCTAssertEqual(status(.damaged), [
            "Can’t save mail · Mail’s records on this Mac are damaged",
            "Your mail files are not affected. Choose View ▸ Rebuild Search Index; it tries again by itself.",
        ])
        var paused = SyncProgress()
        paused.activity = .pausedForSpace(freeBytes: 1, minimumFreeBytes: 2)
        XCTAssertEqual(SyncStatusText.line(paused), DownloadPause.shortText)
        XCTAssertNil(SyncStatusText.advice(paused), "the pause's own words are at the foot of the sidebar")
    }

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
        for path in folders.reversed() { try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: path) }
    }
}

/// A disk's free space that a test sets and the sync reads from any thread.
final class Disk: Sendable {
    private let value = Mutex<Int64>(0)
    var free: Int64 {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}
