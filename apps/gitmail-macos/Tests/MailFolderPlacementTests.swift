import XCTest
import MailAccounts
import MailCore
import MailStore
import MailSync

/// A mail folder in iCloud Drive or a File Provider folder is refused when picked and holds the
/// sync back at launch (GKM-103, MAIL-126). The location check reads the real file system for a
/// local folder; for iCloud Drive and File Provider it is the decision on the path and the
/// `isUbiquitousItem` value, since this test must never touch the Mac's iCloud Drive. The model
/// tests inject the placement (`AccountServices.folderPlacement`) against a real store in a
/// temporary folder.
@MainActor
final class MailFolderPlacementTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var credentials: KeychainCredentialStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm103-placement-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
        defaultsSuite = "gkm103-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        credentials = KeychainCredentialStore(service: "app.hakobs.gitmail.tests.\(UUID().uuidString)", useDataProtectionKeychain: false)
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }

    private func services(placement: MailFolderPlacement) -> AccountServices {
        let connections = AccountConnections(connectTimeout: .seconds(5), commandTimeout: .seconds(15))
        var services = AccountServices(
            credentials: credentials, connections: connections, verifier: AccountVerifier(connections: connections),
            syncOptions: SyncOptions(), defaults: defaults)
        services.folderPlacement = { _ in placement }
        services.freeSpace = { _ in 100_000_000_000 }
        return services
    }

    /// An IMAP account saved in the store with no password on this Mac: without a hold, its sync
    /// starts far enough to say "no password"; with one, it doesn't start at all.
    private func seedConnectedAccount() async throws -> MailAccountID {
        var draft = AccountDraft()
        draft.provider = .other
        draft.address = "someone@example.test"
        draft.imapHost = "imap.example.test"
        draft.smtpHost = "smtp.example.test"
        draft.password = "never saved" // the draft wants one; the Keychain gets none
        let account = MailAccount(displayName: "Work", address: draft.trimmedAddress, connection: try draft.connection())
        let store = try await MailStore.open(locations)
        try await store.save(account)
        return account.id
    }

    // MARK: The location check

    func testAnOrdinaryLocalFolderIsOnThisDevice() throws {
        let folder = root.appendingPathComponent("Mail", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(MailFolderPlacement.of(folder), .onThisDevice)
        XCTAssertEqual(MailFolderPlacement.of(folder.appendingPathComponent("not yet made")), .onThisDevice,
                       "a folder that doesn't exist yet is judged by the one above it")
        XCTAssertNil(MailFolderPlacement.onThisDevice.refusal)
    }

    func testAUbiquitousItemIsRefused() {
        // Desktop & Documents in iCloud: an ordinary-looking path whose items are ubiquitous.
        XCTAssertEqual(MailFolderPlacement.classify(path: "/Users/someone/Documents/Mail", isUbiquitous: true), .iCloudDrive)
        XCTAssertEqual(MailFolderPlacement.classify(path: "/Users/someone/Documents/Mail", isUbiquitous: false), .onThisDevice)
    }

    func testICloudDriveIsRecognisedByItsPath() {
        let path = "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/Mail"
        XCTAssertEqual(MailFolderPlacement.classify(path: path, isUbiquitous: false), .iCloudDrive,
                       "an evicted or not yet indexed folder may not report itself as ubiquitous")
        XCTAssertEqual(MailFolderPlacement.classify(path: path, isUbiquitous: true), .iCloudDrive)
        XCTAssertTrue(MailFolderPlacement.iCloudDrive.refusal?.contains("iCloud Drive") == true)
    }

    func testAFileProviderFolderIsRecognisedByItsPath() {
        let path = "/Users/someone/Library/CloudStorage/Dropbox/Mail"
        XCTAssertEqual(MailFolderPlacement.classify(path: path, isUbiquitous: true), .cloudStorage)
        XCTAssertEqual(MailFolderPlacement.classify(path: path, isUbiquitous: false), .cloudStorage)
        XCTAssertNotNil(MailFolderPlacement.cloudStorage.refusal)
    }

    func testSimilarNamesElsewhereAreNotTakenForSyncedFolders() {
        XCTAssertEqual(MailFolderPlacement.classify(path: "/Volumes/Archive/Mobile Documents/Mail", isUbiquitous: false), .onThisDevice)
        XCTAssertEqual(MailFolderPlacement.classify(path: "/Users/someone/CloudStorage/Mail", isUbiquitous: false), .onThisDevice)
        XCTAssertEqual(MailFolderPlacement.classify(path: "/Users/someone/Library/CloudStorageNotes/Mail", isUbiquitous: false), .onThisDevice)
    }

    // MARK: Picking

    func testPickingAFolderInICloudDriveIsRefusedAndTheCurrentFolderStays() async throws {
        let model = AppModel(locations: locations, services: services(placement: .iCloudDrive))
        await model.open()
        XCTAssertEqual(model.phase, .ready)
        let picked = root.appendingPathComponent("Picked", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)

        XCTAssertEqual(model.mailFolderRefusal(for: picked), MailFolderPlacement.iCloudDrive.refusal)
        await model.useMailFolder(picked)

        XCTAssertEqual(model.actionError, MailFolderPlacement.iCloudDrive.refusal)
        XCTAssertNil(defaults.data(forKey: MailFolderLocation.bookmarkKey), "nothing remembered")
        XCTAssertEqual(model.mailFolder, locations.mailFolder, "the open folder is still open")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: picked.path), [], "nothing written into the picked folder")
    }

    func testALocalFolderIsNotRefused() async throws {
        let model = AppModel(locations: locations, services: services(placement: .onThisDevice))
        XCTAssertNil(model.mailFolderRefusal(for: root))
    }

    // MARK: At launch

    func testAMailFolderInICloudDriveHoldsTheSyncBackAtLaunch() async throws {
        let account = try await seedConnectedAccount()
        let model = AppModel(locations: locations, services: services(placement: .iCloudDrive))
        await model.open()

        XCTAssertEqual(model.phase, .ready, "the mail already there can still be read")
        XCTAssertEqual(model.sync.folderHold, .iCloudDrive)
        XCTAssertFalse(model.sync.isSyncing(account), "nothing started: no download, no actions")
        XCTAssertNil(model.sync.progress[account])
        XCTAssertEqual(model.syncStatus(account), "Sync paused · mail folder is in iCloud Drive")
        XCTAssertTrue(MailFolderPlacement.iCloudDrive.text?.contains("untouched") == true)

        // Every start path asks: starting the one account again still starts nothing.
        let store = try XCTUnwrap(model.mailStore)
        await model.sync.start(try XCTUnwrap(model.accounts.first), store: store)
        XCTAssertFalse(model.sync.isSyncing(account))
    }

    func testAFileProviderMailFolderHoldsTheSyncBackAtLaunch() async throws {
        let account = try await seedConnectedAccount()
        let model = AppModel(locations: locations, services: services(placement: .cloudStorage))
        await model.open()
        XCTAssertEqual(model.sync.folderHold, .cloudStorage)
        XCTAssertFalse(model.sync.isSyncing(account))
        XCTAssertEqual(model.syncStatus(account), "Sync paused · mail folder is synced by another app")
    }

    func testALocalMailFolderStartsAsBefore() async throws {
        let account = try await seedConnectedAccount()
        let model = AppModel(locations: locations, services: services(placement: .onThisDevice))
        await model.open()
        XCTAssertNil(model.sync.folderHold)
        // No password on this Mac for the seeded account: the start got as far as saying so.
        XCTAssertEqual(model.syncStatus(account), "Password needed")
    }
}
