import Foundation
import MailAccounts
import MailCore
import MailProvider
import MailStore
import XCTest
@testable import GitMail

/// The iPhone app's own parts against a real store in a temporary folder: the folder check,
/// the storage budget and the cache, the lifecycle, background refresh against the local test
/// server, and the Keychain round trip the unhosted package tests cannot run (MAIL-050).
@MainActor
final class MobileSessionTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm027-\(UUID().uuidString)", isDirectory: true)
        suite = "gkm027-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }

    private var locations: StoreLocations {
        StoreLocations(mailFolder: root.appendingPathComponent("Mail", isDirectory: true),
                       deviceFolder: root.appendingPathComponent("Device", isDirectory: true))
    }

    private func makeSession(services: AccountServices? = nil, free: Int64? = nil) -> MobileSession {
        var services = services ?? Self.testServices(defaults: defaults)
        services.defaults = defaults
        let model = AppModel(locations: locations, services: services)
        return MobileSession(model: model, defaults: defaults, freeSpace: { _ in free })
    }

    static func testServices(defaults: UserDefaults, trust: TrustPolicy = .system) -> AccountServices {
        let connections = AccountConnections(trust: trust)
        return AccountServices(credentials: KeychainCredentialStore(service: "app.hakobs.gitmail.tests"),
                               connections: connections,
                               verifier: AccountVerifier(connections: connections),
                               syncOptions: StorageBudget.standard.syncOptions,
                               defaults: defaults)
    }

    /// Writes synthetic messages as `.eml` files and imports them, as File ▸ Import does.
    private func importMessages(_ subjects: [String], into model: AppModel) async throws {
        let folder = root.appendingPathComponent("import", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (index, subject) in subjects.enumerated() {
            let raw = "From: Bo <bo@example.net>\r\nTo: me@example.com\r\nSubject: \(subject)\r\nMessage-ID: <\(UUID().uuidString)@example.net>\r\nDate: Tue, 24 Nov 2026 0\(index % 10):00:00 +0000\r\n\r\n\(subject) body.\r\n"
            let url = folder.appendingPathComponent("\(index).eml")
            try Data(raw.utf8).write(to: url)
            urls.append(url)
        }
        await model.importMessages(from: urls)
    }

    // MARK: The mail folder (MAIL-051)

    func testFolderCheckCountsOriginalsLikeARebuild() async throws {
        let session = makeSession()
        await session.ensureOpen()
        try await importMessages(["One", "Two", "Three"], into: session.model)
        XCTAssertEqual(session.model.totalCount, 3)
        XCTAssertEqual(MailFolderCheck.originalCount(in: locations.mailFolder), 3)
        XCTAssertFalse(MailFolderCheck.needsRebuild(mailFolder: locations.mailFolder, indexedCount: 3))
    }

    func testMessageDeletedInFilesIsNoticedAndTheIndexRebuilt() async throws {
        let session = makeSession()
        await session.ensureOpen()
        try await importMessages(["Keep", "Delete in Files"], into: session.model)
        let store = try XCTUnwrap(session.model.mailStore)
        // What Files does: removes one original (and its Markdown) while the app is away.
        let accounts = locations.mailFolder.appendingPathComponent("accounts")
        let eml = try XCTUnwrap(FileManager.default.enumerator(at: accounts, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.first { $0.pathExtension == "eml" })
        try FileManager.default.removeItem(at: eml)
        try? FileManager.default.removeItem(at: eml.deletingPathExtension().appendingPathExtension("md"))
        XCTAssertTrue(MailFolderCheck.needsRebuild(mailFolder: locations.mailFolder, indexedCount: try await store.messageCount()))

        await session.checkMailFolder(store)
        let count = try await store.messageCount()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(session.model.totalCount, 1)
        XCTAssertFalse(session.isCheckingFolder)
    }

    // MARK: Storage (MAIL-051, MAIL-068)

    func testBudgetDefaultsSaveAndSyncOptions() {
        let budget = StorageBudget.load(from: defaults)
        XCTAssertEqual(budget, .standard)
        XCTAssertEqual(budget.syncOptions.historyBudgetBytes, 500 * 1024 * 1024)
        XCTAssertEqual(budget.minimumFreeBytes, 1024 * 1024 * 1024)
        var unlimited = budget
        unlimited.historyBytes = 0
        unlimited.save(to: defaults)
        XCTAssertEqual(StorageBudget.load(from: defaults), unlimited)
        XCTAssertNil(unlimited.syncOptions.historyBudgetBytes)
    }

    func testChangedBudgetReachesTheNextSync() async {
        let session = makeSession()
        var budget = session.budget
        budget.historyBytes = 100 * 1024 * 1024
        await session.setBudget(budget)
        XCTAssertEqual(session.model.sync.services.syncOptions.historyBudgetBytes, 100 * 1024 * 1024)
        XCTAssertEqual(StorageBudget.load(from: defaults).historyBytes, 100 * 1024 * 1024)
    }

    func testCacheIsExcludedFromBackupAndTrimmedOldestFirstKeepingCrashRecords() throws {
        let device = locations.deviceFolder
        try DeviceCache.prepare(deviceFolder: device)
        let cache = DeviceCache.folder(in: device)
        XCTAssertEqual(try cache.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

        let attempts = cache.appendingPathComponent("attachment-text-attempts", isDirectory: true)
        try FileManager.default.createDirectory(at: attempts, withIntermediateDirectories: true)
        let record = attempts.appendingPathComponent("abc.inflight")
        try Data(count: 64 * 1024).write(to: record)
        let preview = cache.appendingPathComponent("quicklook", isDirectory: true)
        try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
        var files: [URL] = []
        for index in 0..<4 {
            let file = preview.appendingPathComponent("\(index).bin")
            try Data(count: 256 * 1024).write(to: file)
            // Oldest first: file 0 was used longest ago.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index - 10) * 60)], ofItemAtPath: file.path)
            var url = file
            var values = URLResourceValues()
            values.contentAccessDate = Date(timeIntervalSinceNow: Double(index - 10) * 60)
            try url.setResourceValues(values)
            files.append(file)
        }

        let removed = DeviceCache.trim(deviceFolder: device, to: 600 * 1024)
        XCTAssertGreaterThan(removed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[1].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[3].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path), "a crash record is never evicted")
    }

    func testLowStorageStopsTheSyncWithAMessage() async {
        let session = makeSession(free: 200 * 1024 * 1024)
        await session.becameActive()
        XCTAssertEqual(session.model.phase, .ready)
        XCTAssertNotNil(session.storageNotice)
        XCTAssertFalse(session.model.sync.isRunning)
    }

    // MARK: Lifecycle (MAIL-053)

    func testBackgroundStopsSyncAndAttachmentTextAndForegroundStartsThemAgain() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        let session = makeSession(services: Self.testServices(defaults: defaults, trust: server.trust))
        await session.becameActive()
        try await session.model.addAccount(Self.draft(for: user))
        XCTAssertTrue(session.model.sync.isRunning)

        await session.enteredBackground(ImmediateBackgroundTasks())
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.model.sync.isRunning, "no IMAP connection or IDLE in the background")
        XCTAssertFalse(session.model.extractsAttachmentText, "no attachment parsing in the background (MAIL-052)")

        await session.becameActive()
        XCTAssertTrue(session.model.sync.isRunning)
        XCTAssertTrue(session.model.extractsAttachmentText)
        try? KeychainCredentialStore(service: "app.hakobs.gitmail.tests").delete(for: session.model.accounts[0].id)
    }

    func testBackgroundRefreshBringsInNewMailAndStopsAgain() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        let session = makeSession(services: Self.testServices(defaults: defaults, trust: server.trust))
        await session.becameActive()
        let account = try await session.model.addAccount(Self.draft(for: user))
        await session.enteredBackground(ImmediateBackgroundTasks())

        // Mail arrives while the app is in the background.
        try await server.append(["While you were away", "And another"], for: user)
        let run = await session.backgroundRefresh()

        XCTAssertEqual(run.kind, .refresh)
        XCTAssertFalse(run.cutShort)
        XCTAssertEqual(run.imported, 2)
        XCTAssertEqual(session.lastBackgroundRun, run)
        XCTAssertFalse(session.model.sync.isRunning, "the sync stops when the background task is done")
        XCTAssertEqual(session.model.totalCount, 2)
        try? KeychainCredentialStore(service: "app.hakobs.gitmail.tests").delete(for: account.id)
    }

    func testBackgroundRefreshNeverRunsOverTheOpenApp() async {
        let session = makeSession()
        await session.becameActive()
        let run = await session.backgroundRefresh()
        XCTAssertEqual(run.imported, 0)
        XCTAssertNil(session.lastBackgroundRun)
    }

    // MARK: Keychain (MAIL-050: needs the app's entitlement, so it runs here)

    func testKeychainRoundTripInTheApp() throws {
        let store = KeychainCredentialStore(service: "app.hakobs.gitmail.tests")
        let account = MailAccountID("keychain-\(UUID().uuidString)")
        try store.save(Secret("first"), for: account)
        try store.save(Secret("second"), for: account)
        XCTAssertEqual(try store.secret(for: account)?.withValue { $0 }, "second")
        try store.delete(for: account)
        XCTAssertNil(try store.secret(for: account))
    }

    static func draft(for user: LocalMailServer.User) -> AccountDraft {
        var draft = AccountDraft()
        draft.provider = .other
        draft.address = user.address
        draft.password = user.password
        draft.imapHost = "localhost"
        draft.imapPort = 3993
        draft.smtpHost = "localhost"
        draft.smtpPort = 3465
        draft.smtpSecurity = .implicitTLS
        return draft
    }
}

/// Runs the "finish in the background" work directly; nothing expires.
@MainActor
struct ImmediateBackgroundTasks: BackgroundTaskRunning {
    func begin(_ name: String, expiration: @escaping @MainActor () -> Void) -> Int { 1 }
    func end(_ id: Int) {}
}
