import XCTest
import MailCore
import MailTestSupport
@testable import MailStore

/// A store opened read-only writes nothing into the mail folder (GKM-104, MAIL-135): not when it
/// opens (layout file, crash recovery, index rebuild), and every writer of the folder refuses
/// with the reason. The index and the device state stay writable.
final class ReadOnlyStoreTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let account = MailAccountID("acct-1")
    private let reason = "The folder is read-only."

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm104-store-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Every path under the mail folder with its size and modification time.
    private func snapshot() throws -> [String: String] {
        var found: [String: String] = [:]
        guard let walker = FileManager.default.enumerator(
            at: locations.mailFolder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return found }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            found[url.path] = "\(values.fileSize ?? -1) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return found
    }

    func testAReadOnlyStoreOpensAFolderThatDoesNotExistWithoutMakingIt() async throws {
        let store = try await MailStore.open(locations, readOnlyReason: reason)
        XCTAssertTrue(store.isReadOnly)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.mailFolder.path), "not even created")
        let count = try await store.messageCount()
        XCTAssertEqual(count, 0)
    }

    func testOpeningReadOnlyLeavesTheFolderAsItIsAndSaysWhatItSkipped() async throws {
        let writable = try await MailStore.open(locations)
        try await writable.save(MailAccount(id: account, displayName: "Work", address: "ada@example.com"))
        let stored = try await writable.ingest(SyntheticMail.corpus[0], account: account)
        // What a crash leaves: a temporary file in the month folder, and a journal entry this
        // device can't read (a writable open removes both and rebuilds the index).
        let month = try await writable.message(stored.id).emlURL.deletingLastPathComponent()
        let stray = month.appendingPathComponent(".left-behind\(AtomicWriter.partialSuffix)")
        try Data("half".utf8).write(to: stray)
        try FileManager.default.createDirectory(at: locations.journalFolder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: locations.journalFolder.appendingPathComponent("broken.json"))
        let before = try snapshot()

        let store = try await MailStore.open(locations, readOnlyReason: reason)

        let deferred = await store.recoveryDeferred
        XCTAssertTrue(deferred, "recovery was due and did not start")
        XCTAssertEqual(try snapshot(), before, "nothing in the mail folder changed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
        let count = try await store.messageCount()
        XCTAssertEqual(count, 1, "the mail is there to read")
        let message = try await store.message(stored.id)
        XCTAssertEqual(message.front.id, stored.id)
    }

    func testEveryWriterOfTheFolderRefusesWithTheReason() async throws {
        let writable = try await MailStore.open(locations)
        try await writable.save(MailAccount(id: account, displayName: "Work", address: "ada@example.com"))
        let stored = try await writable.ingest(SyntheticMail.corpus[0], account: account)
        let space = try await writable.createSpace(name: "Taxes")
        let before = try snapshot()

        let store = try await MailStore.open(locations, readOnlyReason: reason)

        func refused(_ name: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                XCTFail("\(name) wrote into a read-only folder")
            } catch let error as MailStoreError {
                XCTAssertEqual(error, .readOnly(reason), name)
                XCTAssertEqual(error.description, reason, name)
            } catch {
                XCTFail("\(name): \(error)")
            }
        }
        await refused("ingest") { try await store.ingest(SyntheticMail.corpus[1], account: account) }
        await refused("save account") { try await store.save(MailAccount(id: account, displayName: "New", address: "")) }
        await refused("create space") { _ = try await store.createSpace(name: "Another") }
        await refused("delete space") { try await store.deleteSpace(space.id) }
        await refused("disconnect") { try await store.disconnectAccount(account, mail: .remove) }
        await refused("rebuild") { try await store.rebuildIndex() }
        XCTAssertEqual(try snapshot(), before)
        let count = try await store.messageCount()
        XCTAssertEqual(count, 1)
        _ = stored
    }

    func testAWritableStoreStillRecoversAndWrites() async throws {
        let store = try await MailStore.open(locations)
        XCTAssertFalse(store.isReadOnly)
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.layoutURL.path), "layout.json is written as before")
        try await store.save(MailAccount(id: account, displayName: "Work", address: "ada@example.com"))
        try await store.ingest(SyntheticMail.corpus[0], account: account)
        let count = try await store.messageCount()
        XCTAssertEqual(count, 1)
    }
}
