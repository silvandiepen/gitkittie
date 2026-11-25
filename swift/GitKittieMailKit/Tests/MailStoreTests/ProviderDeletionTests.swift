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
