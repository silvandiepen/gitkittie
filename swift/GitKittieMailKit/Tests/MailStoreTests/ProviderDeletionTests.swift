import XCTest
import MailCore
@testable import MailStore

/// Mail deleted at the provider (GKM-011, answered by Sil; MAIL-075): kept and marked with
/// when, or removed only when the account says so and nothing keeps it. Against a real store
/// in a temporary folder; the sync's side runs against the test server in MailSyncIntegrationTests.
final class ProviderDeletionTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let account = MailAccountID("acct-1")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm042-deletions-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func location(_ mailbox: String, _ uid: UInt32) -> RemoteLocation {
        RemoteLocation(mailbox: mailbox, uidValidity: 7, uid: uid)
    }

    private func summary(_ store: MailStore, _ id: MailMessageID) async throws -> MessageSummary? {
        try await store.summaries(ids: [id]).first
    }

    func testAMessageThatLeavesItsLastFolderIsNoticedAndAMoveIsNot() async throws {
        let store = try await MailStore.open(locations)
        let moved = try await store.ingest(SyntheticMail.plain(subject: "Moved", messageID: "moved@example.com", body: "a"),
                                           account: account, remote: location("INBOX", 1)).id
        let copied = try await store.ingest(SyntheticMail.plain(subject: "Two folders", messageID: "two@example.com", body: "b"),
                                            account: account, remote: location("INBOX", 2)).id
        try await store.record(location("Work", 9), for: copied, account: account)
        let deleted = try await store.ingest(SyntheticMail.plain(subject: "Deleted", messageID: "deleted@example.com", body: "c"),
                                             account: account, remote: location("INBOX", 3)).id

        let noticed = Date(timeIntervalSince1970: 1_800_000_000)
        for uid: UInt32 in [1, 2, 3] { try await store.forget(location("INBOX", uid), account: account, now: noticed) }
        // The moved one turns up in Archive in the same pass.
        try await store.record(location("Archive", 4), for: moved, account: account)

        let candidates = try await store.deletionCandidates(account: account)
        XCTAssertEqual(candidates, [DeletionCandidate(id: deleted, messageID: "deleted@example.com", noticedAt: noticed)],
                       "still in Work, or found again in Archive: not deleted")
        let shownBefore = try await summary(store, deleted)
        XCTAssertNil(shownBefore?.deletedAtProvider, "not shown as deleted until a pass confirms it")

        try await store.confirmDeletions(candidates, account: account)
        let shown = try await summary(store, deleted)
        XCTAssertEqual(shown?.deletedAtProvider, noticed)
        let left = try await store.deletionCandidates(account: account)
        XCTAssertEqual(left, [])
        let count = try await store.messageCount()
        XCTAssertEqual(count, 3, "nothing local is deleted")

        // Survives a rebuilt index: the mark is device state, like flags.
        try await store.rebuildIndex()
        let rebuilt = try await summary(store, deleted)
        XCTAssertEqual(rebuilt?.deletedAtProvider, noticed)
        let reopened = try await MailStore.open(locations)
        let again = try await summary(reopened, deleted)
        XCTAssertEqual(again?.deletedAtProvider, noticed)

        // Restored at the provider (back from its Trash): the mark goes.
        try await reopened.record(location("INBOX", 20), for: deleted, account: account)
        _ = try await reopened.removeMailDeletedAtProvider(account: account)
        let restored = try await summary(reopened, deleted)
        XCTAssertNil(restored?.deletedAtProvider)
        let marks = try await reopened.deletedAtProvider(account: account)
        XCTAssertEqual(marks, [:])
    }

    func testAFolderDeletedAtTheProviderTakesOnlyTheMessagesThatWereOnlyThere() async throws {
        let store = try await MailStore.open(locations)
        try await store.replaceSyncedFolders([SyncedFolder(name: "INBOX", path: ["INBOX"]), SyncedFolder(name: "Old", path: ["Old"])],
                                             account: account)
        let only = try await store.ingest(SyntheticMail.plain(subject: "Only in Old", body: "a"), account: account, remote: location("Old", 1)).id
        let both = try await store.ingest(SyntheticMail.plain(subject: "Also in INBOX", body: "b"), account: account, remote: location("Old", 2)).id
        try await store.record(location("INBOX", 5), for: both, account: account)
        try await store.replaceSyncedFolders([SyncedFolder(name: "INBOX", path: ["INBOX"])], account: account)
        let candidates = try await store.deletionCandidates(account: account)
        XCTAssertEqual(candidates.map(\.id), [only])
        XCTAssertNil(candidates.first?.messageID, "stored without a Message-ID: the sync cannot search for it")
    }

    /// A check that could not tell (MAIL-104) sends the candidate behind the others: never
    /// undecided first, oldest first, then the least recently checked (GKM-076, MAIL-105). It is
    /// never confirmed for that, and the record survives reopening the store.
    func testACandidateThatCouldNotBeDecidedGoesBehindTheOthers() async throws {
        let store = try await MailStore.open(locations)
        var ids: [MailMessageID] = []
        for uid: UInt32 in 1...4 {
            ids.append(try await store.ingest(SyntheticMail.plain(subject: "Receipt \(uid)", body: "\(uid)"), account: account,
                                              remote: location("INBOX", uid)).id)
        }
        let noticed = Date(timeIntervalSince1970: 1_800_000_000)
        for (offset, uid) in [UInt32(1), 2, 3, 4].enumerated() {
            try await store.forget(location("INBOX", uid), account: account, now: noticed.addingTimeInterval(Double(offset)))
        }
        let first = try await store.deletionCandidates(account: account)
        XCTAssertEqual(first.map(\.id), ids, "oldest first")
        XCTAssertEqual(first.map(\.undecidedChecks), [0, 0, 0, 0])

        let earlier = noticed.addingTimeInterval(60)
        let later = noticed.addingTimeInterval(120)
        try await store.recordUndecidedDeletionCheck(of: ids[1], account: account, now: later)
        try await store.recordUndecidedDeletionCheck(of: ids[0], account: account, now: earlier)
        try await store.recordUndecidedDeletionCheck(of: ids[0], account: account, now: later.addingTimeInterval(60))
        let reordered = try await MailStore.open(locations).deletionCandidates(account: account)
        XCTAssertEqual(reordered.map(\.id), [ids[2], ids[3], ids[1], ids[0]],
                       "never undecided first, then the least recently checked")
        XCTAssertEqual(reordered.map(\.undecidedChecks), [0, 0, 1, 2])
        XCTAssertEqual(reordered.map(\.checkedAt), [nil, nil, later, later.addingTimeInterval(60)])
        XCTAssertEqual(reordered.map(\.noticedAt), [2, 3, 1, 0].map { noticed.addingTimeInterval(Double($0)) })
        let marks = try await store.deletedAtProvider(account: account)
        XCTAssertEqual(marks, [:], "a check that could not tell confirms nothing")

        // Confirmed, it takes no more checks on record.
        try await store.confirmDeletions(reordered, account: account)
        try await store.recordUndecidedDeletionCheck(of: ids[2], account: account, now: later)
        let left = try await store.deletionCandidates(account: account)
        XCTAssertEqual(left, [])
    }

    /// sync.sqlite 6 → 7: a notice from before keeps its place and has no check on record.
    func testANoticeFromSchema6HasNoCheckOnRecordAfterTheMigration() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("sync.sqlite")
        let noticed = Date(timeIntervalSince1970: 1_800_000_000)
        let id = MailMessageID()
        do {
            let mapping = try RemoteMapping(url: url)
            try mapping.noticeDeletion(of: id, at: noticed)
            // As schema 6 wrote it.
            try mapping.database.execute("""
                ALTER TABLE provider_deletions DROP COLUMN checked_at;
                ALTER TABLE provider_deletions DROP COLUMN undecided_checks;
                """)
            try mapping.database.setUserVersion(6)
        }
        let migrated = try RemoteMapping(url: url)
        XCTAssertEqual(try migrated.database.userVersion, RemoteMapping.schemaVersion)
        XCTAssertEqual(try migrated.unconfirmedDeletions(), [NoticedDeletion(id: id, noticedAt: noticed)])
        try migrated.recordUndecidedCheck(of: id, at: noticed.addingTimeInterval(60))
        XCTAssertEqual(try migrated.unconfirmedDeletions(),
                       [NoticedDeletion(id: id, noticedAt: noticed, checkedAt: noticed.addingTimeInterval(60), undecidedChecks: 1)])
    }

    /// "Remove mail deleted elsewhere": the copy goes, files and all, unless it is pinned, in a
    /// space, or in the action journal (an open change or Undo's seven days).
    func testRemovalDeletesTheLocalCopyUnlessSomethingKeepsIt() async throws {
        let store = try await MailStore.open(locations)
        func add(_ name: String, _ uid: UInt32, attachment: Bool = false) async throws -> MailMessageID {
            let eml = attachment
                ? SyntheticMail.withAttachment(subject: name, messageID: "\(name)@example.com", body: name, fileName: "\(name).pdf",
                                               attachment: Data("only \(name) has this".utf8))
                : SyntheticMail.plain(subject: name, messageID: "\(name)@example.com", body: name)
            return try await store.ingest(eml, account: account, remote: location("INBOX", uid)).id
        }
        let plain = try await add("plain", 1, attachment: true)
        let pinned = try await add("pinned", 2)
        let spaced = try await add("spaced", 3)
        let journaled = try await add("journaled", 4)
        let kept = try await add("kept", 5)
        _ = try await store.pin(.message(pinned))
        let space = try await store.createSpace(name: "Trip")
        _ = try await store.addMessages([spaced], to: space.id)
        _ = try await store.perform([MailChange(journaled, .setSeen(true))])

        let plainFiles = try await store.message(plain)
        let blob = try XCTUnwrap(plainFiles.front.attachments.first?.blob)
        let blobURL = locations.mailFolder.appendingPathComponent("blobs").appendingPathComponent(blob)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobURL.path))

        for uid: UInt32 in 1...4 { try await store.forget(location("INBOX", uid), account: account) }
        let candidates = try await store.deletionCandidates(account: account)
        XCTAssertEqual(Set(candidates.map(\.id)), [plain, pinned, spaced, journaled])
        try await store.confirmDeletions(candidates, account: account)

        let keepPinned = try await store.deletionKeep(pinned, account: account)
        let keepSpaced = try await store.deletionKeep(spaced, account: account)
        let keepJournaled = try await store.deletionKeep(journaled, account: account)
        XCTAssertEqual(keepPinned, .pinned)
        XCTAssertEqual(keepSpaced, .inSpace)
        XCTAssertEqual(keepJournaled, .inActionJournal)

        let removed = try await store.removeMailDeletedAtProvider(account: account)
        XCTAssertEqual(removed, [plain])
        XCTAssertFalse(FileManager.default.fileExists(atPath: plainFiles.emlURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plainFiles.markdownURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobURL.path), "an attachment only it used goes too")
        let gone = try await summary(store, plain)
        XCTAssertNil(gone)
        let remaining = try await store.messageCount()
        XCTAssertEqual(remaining, 4)
        let stillMarked = try await store.deletedAtProvider(account: account)
        XCTAssertEqual(Set(stillMarked.keys), [pinned, spaced, journaled], "kept, and still shown as deleted")
        let untouched = try await summary(store, kept)
        XCTAssertNil(untouched?.deletedAtProvider)

        // After a rebuild nothing comes back: the folder no longer has it.
        try await store.rebuildIndex()
        let afterRebuild = try await store.messageCount()
        XCTAssertEqual(afterRebuild, 4)
        let candidatesAfter = try await store.deletionCandidates(account: account)
        XCTAssertEqual(candidatesAfter, [])
    }
}
