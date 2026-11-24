import XCTest
import MailCore
@testable import MailStore

/// The device state the sync keeps (GKM-011) and disconnecting an account (GKM-010), against a
/// real store in a temporary folder.
final class SyncStateTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let account = MailAccountID("acct-1")
    private let other = MailAccountID("acct-2")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("syncstate-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func location(_ mailbox: String, _ uid: UInt32, validity: UInt32 = 7) -> RemoteLocation {
        RemoteLocation(mailbox: mailbox, uidValidity: validity, uid: uid)
    }

    func testFolderListKeepsCursorsAndDropsFoldersGoneAtTheProvider() async throws {
        let store = try await MailStore.open(locations)
        try await store.replaceSyncedFolders([
            SyncedFolder(name: "INBOX", path: ["INBOX"], role: "inbox"),
            SyncedFolder(name: "Old", path: ["Old"]),
        ], account: account)
        try await store.saveCursor(folder: "INBOX", uidValidity: 7, highestUID: 12, historyComplete: true, serverCount: 3, account: account)
        let kept = try await store.ingest(SyntheticMail.plain(subject: "kept", body: "a"), account: account, remote: location("Old", 1))

        let removed = try await store.replaceSyncedFolders([
            SyncedFolder(name: "Archive", path: ["Archive"], role: "archive"),
            SyncedFolder(name: "INBOX", path: ["Inbox"], role: "inbox"),
        ], account: account)
        XCTAssertEqual(removed, ["Old"])
        let folders = try await store.syncedFolders(account: account)
        XCTAssertEqual(folders.map(\.name), ["Archive", "INBOX"], "the provider's order")
        XCTAssertEqual(folders[1], SyncedFolder(name: "INBOX", path: ["Inbox"], role: "inbox", uidValidity: 7,
                                                highestUID: 12, historyComplete: true, serverCount: 3))
        XCTAssertNil(folders[0].uidValidity)
        let gone = try await store.remoteLocations(of: kept.id, account: account)
        XCTAssertEqual(gone, [], "the folder is gone, so is the location")
        let count = try await store.messageCount()
        XCTAssertEqual(count, 1, "the message itself stays")
    }

    func testKnownUIDsFolderSummariesFlagsAndCounters() async throws {
        let store = try await MailStore.open(locations)
        let a = try await store.ingest(SyntheticMail.plain(subject: "a", date: "Mon, 23 Nov 2026 10:00:00 +0000", body: "a"),
                                       account: account, remote: location("INBOX", 1))
        let b = try await store.ingest(SyntheticMail.plain(subject: "b", date: "Tue, 24 Nov 2026 10:00:00 +0000", body: "b"),
                                       account: account, remote: location("INBOX", 2))
        _ = try await store.ingest(SyntheticMail.plain(subject: "c", body: "c"), account: account, remote: location("Archive", 1))
        try await store.record(location("Archive", 5), for: a.id, account: account)

        let inbox = try await store.knownUIDs(mailbox: "INBOX", uidValidity: 7, account: account)
        XCTAssertEqual(inbox, [1: a.id, 2: b.id])
        let stale = try await store.knownUIDs(mailbox: "INBOX", uidValidity: 8, account: account)
        XCTAssertEqual(stale, [:])
        let listed = try await store.summaries(account: account, mailbox: "INBOX").map(\.subject)
        XCTAssertEqual(listed, ["b", "a"], "newest first")
        let archive = try await store.summaries(account: account, mailbox: "Archive").map(\.subject)
        XCTAssertEqual(Set(archive), ["a", "c"])
        let otherAccount = try await store.summaries(account: other, mailbox: "INBOX")
        XCTAssertEqual(otherAccount, [])
        let inboxCount = try await store.messageCount(account: account, mailbox: "INBOX")
        XCTAssertEqual(inboxCount, 2)

        let read = MailMessageFlags(seen: true, flagged: true, keywords: ["$Forwarded", "$Junk"])
        try await store.setFlags([a.id: read, b.id: MailMessageFlags()], account: account)
        let flags = try await store.flags(of: [a.id, b.id], account: account)
        XCTAssertEqual(flags, [a.id: read, b.id: MailMessageFlags()])

        try await store.addImportedBytes(1_000, account: account)
        try await store.addImportedBytes(234, account: account)
        let bytes = try await store.importedBytes(account: account)
        XCTAssertEqual(bytes, 1_234)
    }

    func testAVersionOneMappingIsMigratedWithItsLocations() async throws {
        let id = MailMessageID()
        let url = locations.deviceFolder.appendingPathComponent("state/acct-1/sync.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let v1 = try SQLiteDatabase(url: url)
            try v1.execute("""
                CREATE TABLE mailboxes (name TEXT PRIMARY KEY, uid_validity INTEGER NOT NULL);
                CREATE TABLE locations (mailbox TEXT NOT NULL, uid_validity INTEGER NOT NULL, uid INTEGER NOT NULL,
                  local_id TEXT NOT NULL, PRIMARY KEY (mailbox, uid_validity, uid));
                CREATE INDEX locations_by_local_id ON locations (local_id);
                INSERT INTO mailboxes VALUES ('INBOX', 7);
                INSERT INTO locations VALUES ('INBOX', 7, 3, '\(id.rawValue)');
                PRAGMA user_version = 1;
                """)
        }
        let store = try await MailStore.open(locations)
        let known = try await store.knownUIDs(mailbox: "INBOX", uidValidity: 7, account: account)
        XCTAssertEqual(known, [3: id])
        let folders = try await store.syncedFolders(account: account)
        XCTAssertEqual(folders, [])
    }

    private func writeMapping(_ sql: String) throws {
        let url = locations.deviceFolder.appendingPathComponent("state/acct-1/sync.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try SQLiteDatabase(url: url)
        try database.execute(sql)
    }

    private static let versionOneTables = """
        CREATE TABLE mailboxes (name TEXT PRIMARY KEY, uid_validity INTEGER NOT NULL);
        CREATE TABLE locations (mailbox TEXT NOT NULL, uid_validity INTEGER NOT NULL, uid INTEGER NOT NULL,
          local_id TEXT NOT NULL, PRIMARY KEY (mailbox, uid_validity, uid));
        CREATE INDEX locations_by_local_id ON locations (local_id);
        """

    func testTheReadersVersionTwoKeepsItsFlagsAndGainsTheSyncState() async throws {
        let id = MailMessageID()
        try writeMapping(Self.versionOneTables + """
            CREATE TABLE flags (local_id TEXT PRIMARY KEY, seen INTEGER NOT NULL, flagged INTEGER NOT NULL);
            INSERT INTO mailboxes VALUES ('INBOX', 7);
            INSERT INTO locations VALUES ('INBOX', 7, 3, '\(id.rawValue)');
            INSERT INTO flags VALUES ('\(id.rawValue)', 1, 1);
            PRAGMA user_version = 2;
            """)
        let store = try await MailStore.open(locations)
        let flags = try await store.flags(of: [id], account: account)
        XCTAssertEqual(flags[id], MailMessageFlags(seen: true, flagged: true))
        try await store.saveCursor(folder: "INBOX", uidValidity: 7, highestUID: 3, historyComplete: true, serverCount: 1, account: account)
        let folders = try await store.syncedFolders(account: account)
        XCTAssertEqual(folders.map(\.highestUID), [3])
    }

    func testAPreMergeSyncVersionTwoMovesItsFlagsIntoTheSharedTable() async throws {
        let id = MailMessageID()
        try writeMapping(Self.versionOneTables + """
            CREATE TABLE folder_state (name TEXT PRIMARY KEY, path TEXT NOT NULL, role TEXT, position INTEGER NOT NULL,
              uid_validity INTEGER, highest_uid INTEGER NOT NULL DEFAULT 0, history_complete INTEGER NOT NULL DEFAULT 0,
              server_count INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE message_flags (local_id TEXT PRIMARY KEY, seen INTEGER NOT NULL, answered INTEGER NOT NULL,
              flagged INTEGER NOT NULL, draft INTEGER NOT NULL, keywords TEXT NOT NULL);
            CREATE TABLE counters (name TEXT PRIMARY KEY, value INTEGER NOT NULL);
            INSERT INTO folder_state VALUES ('INBOX', '["INBOX"]', 'inbox', 0, 7, 9, 1, 2);
            INSERT INTO message_flags VALUES ('\(id.rawValue)', 1, 1, 0, 0, '$Forwarded');
            INSERT INTO counters VALUES ('imported_bytes', 42);
            PRAGMA user_version = 2;
            """)
        let store = try await MailStore.open(locations)
        let flags = try await store.flags(of: [id], account: account)
        XCTAssertEqual(flags[id], MailMessageFlags(seen: true, answered: true, keywords: ["$Forwarded"]))
        let folders = try await store.syncedFolders(account: account)
        XCTAssertEqual(folders.first?.highestUID, 9)
        let bytes = try await store.importedBytes(account: account)
        XCTAssertEqual(bytes, 42)
    }

    func testSyncedFlagsReachTheListAndALocalChangeKeepsTheRest() async throws {
        let store = try await MailStore.open(locations)
        let a = try await store.ingest(SyntheticMail.plain(subject: "a", body: "a"), account: account, remote: location("INBOX", 1))
        try await store.setFlags([a.id: MailMessageFlags(seen: false, answered: true, flagged: true, keywords: ["$Label1"])], account: account)
        let listed = try await store.summaries(account: account, mailbox: "INBOX")
        XCTAssertEqual(listed.first?.isUnread, true)
        XCTAssertEqual(listed.first?.isFlagged, true)

        try await store.setFlags(MessageFlags(seen: true, flagged: true), for: a.id)
        let after = try await store.flags(of: [a.id], account: account)
        XCTAssertEqual(after[a.id], MailMessageFlags(seen: true, answered: true, flagged: true, keywords: ["$Label1"]),
                       "marking read keeps what only the sync knows")
    }

    // MARK: Disconnecting

    private func seedTwoAccounts(_ store: MailStore) async throws -> (only: MailMessageID, shared: String, own: String) {
        let connection = MailConnectionSettings(
            kind: .imap,
            imap: MailServerSettings(host: "imap.example.com", port: 993, security: .implicitTLS, username: "ada"),
            smtp: MailServerSettings(host: "smtp.example.com", port: 587, security: .startTLS, username: "ada@example.com"))
        try await store.save(MailAccount(id: account, displayName: "Work", address: "ada@example.com", connection: connection))
        try await store.save(MailAccount(id: other, displayName: "Home", address: "ada@example.org", connection: connection))
        let sharedFile = Data("%PDF-1.4 synthetic shared".utf8)
        let ownFile = Data("%PDF-1.4 synthetic only work".utf8)
        let only = try await store.ingest(SyntheticMail.withAttachment(subject: "Plan", messageID: "plan@example.com", body: "See plan.",
                                                                       fileName: "plan.pdf", attachment: ownFile),
                                          account: account, remote: location("INBOX", 1))
        _ = try await store.ingest(SyntheticMail.withAttachment(subject: "Shared", messageID: "shared-1@example.com", body: "Shared.",
                                                                fileName: "shared.pdf", attachment: sharedFile),
                                   account: account, remote: location("INBOX", 2))
        _ = try await store.ingest(SyntheticMail.withAttachment(subject: "Shared", messageID: "shared-2@example.com", body: "Shared too.",
                                                                fileName: "shared.pdf", attachment: sharedFile),
                                   account: other, remote: location("INBOX", 1))
        try await store.saveCursor(folder: "INBOX", uidValidity: 7, highestUID: 2, historyComplete: true, serverCount: 2, account: account)
        return (only.id, Hashing.sha256Hex(sharedFile), Hashing.sha256Hex(ownFile))
    }

    func testDisconnectKeepingMailLeavesItReadableAndForgetsTheSyncState() async throws {
        let store = try await MailStore.open(locations)
        let seeded = try await seedTwoAccounts(store)
        try await store.disconnectAccount(account, mail: .keep)

        let accounts = try await store.accounts()
        let work = try XCTUnwrap(accounts.first { $0.id == account })
        XCTAssertNil(work.connection, "nothing syncs it any more")
        XCTAssertEqual(work.displayName, "Work")
        XCTAssertNotNil(accounts.first { $0.id == other }?.connection)
        let summaries = try await store.summaries(account: account)
        XCTAssertEqual(summaries.count, 2)
        _ = try await store.originalData(of: seeded.only)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.stateFolder("acct-1").path))
        let folders = try await store.syncedFolders(account: account)
        XCTAssertEqual(folders, [], "a fresh, empty state")
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.stateFolder("acct-2").appendingPathComponent("sync.sqlite").path))
    }

    func testDisconnectRemovingMailDeletesItsFilesAndOnlyItsBlobs() async throws {
        let store = try await MailStore.open(locations)
        let seeded = try await seedTwoAccounts(store)
        try await store.disconnectAccount(account, mail: .remove)

        let fileManager = FileManager.default
        XCTAssertFalse(fileManager.fileExists(atPath: locations.accountsFolder.appendingPathComponent("acct-1").path))
        XCTAssertFalse(fileManager.fileExists(atPath: locations.blobsFolder.appendingPathComponent(seeded.own).path))
        XCTAssertTrue(fileManager.fileExists(atPath: locations.blobsFolder.appendingPathComponent(seeded.shared).path),
                      "the other account still links to it")
        let accounts = try await store.accounts()
        XCTAssertEqual(accounts.map(\.id), [other])
        let count = try await store.messageCount()
        XCTAssertEqual(count, 1)
        let found = try await store.search("plan")
        XCTAssertEqual(found, [])

        // A rebuild from the folder agrees: nothing of the account comes back.
        try await store.rebuildIndex()
        let rebuilt = try await store.messageCount()
        XCTAssertEqual(rebuilt, 1)
    }

    func testExportMakesAMailFolderOfItsOwnThatOpens() async throws {
        let store = try await MailStore.open(locations)
        let seeded = try await seedTwoAccounts(store)
        let destination = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let exported = try await store.exportAccount(account, to: destination)
        XCTAssertEqual(exported.lastPathComponent, "Work Mail")
        let second = try await store.exportAccount(account, to: destination)
        XCTAssertEqual(second.lastPathComponent, "Work Mail 2", "never overwrites")
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appendingPathComponent("blobs/\(seeded.own)").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appendingPathComponent("blobs/\(seeded.shared)").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [])

        let reopened = try await MailStore.open(StoreLocations(mailFolder: exported, deviceFolder: root.appendingPathComponent("ExportState")))
        let accounts = try await reopened.accounts()
        XCTAssertEqual(accounts.map(\.displayName), ["Work"])
        let summaries = try await reopened.summaries()
        XCTAssertEqual(Set(summaries.map(\.subject)), ["Plan", "Shared"])
        let original = try await store.originalData(of: seeded.only)
        let copy = try await reopened.originalData(of: seeded.only)
        XCTAssertEqual(copy, original)
        let verify = try await reopened.verifyIntegrity()
        XCTAssertEqual(verify, [])
    }
}
