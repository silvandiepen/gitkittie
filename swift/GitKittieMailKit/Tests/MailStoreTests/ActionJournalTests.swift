import XCTest
import MailCore
@testable import MailStore

/// The action journal's local side (GKM-015, MAIL-034/035): actions show at once, survive sync
/// writes, index rebuilds and UIDVALIDITY resets until the provider has them, Undo cancels queued
/// rows, and the provider wins when it changed the same flag. The replay against a real server
/// is tested in GitKittieMailProviders (MailActionsIntegrationTests).
final class ActionJournalTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let account = MailAccountID("acct-actions")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func location(_ mailbox: String, _ uid: UInt32, validity: UInt32 = 7) -> RemoteLocation {
        RemoteLocation(mailbox: mailbox, uidValidity: validity, uid: uid)
    }

    private func synced(_ store: MailStore, _ subject: String, uid: UInt32) async throws -> MailMessageID {
        let result = try await store.ingest(SyntheticMail.plain(subject: subject, body: subject), account: account,
                                            remote: location("INBOX", uid))
        try await store.setFlags([result.id: MailMessageFlags()], account: account)
        return result.id
    }

    private func inbox(_ store: MailStore) async throws -> [String] {
        try await store.summaries(account: account, mailbox: "INBOX").compactMap(\.subject).sorted()
    }

    func testActionsShowAtOnceAndAreQueued() async throws {
        let store = try await MailStore.open(locations)
        let a = try await synced(store, "a", uid: 1)
        let b = try await synced(store, "b", uid: 2)
        let batch = try await store.perform([MailChange(a, .setSeen(true)), MailChange(a, .setFlagged(true)),
                                             MailChange(b, .move(from: "INBOX", to: "Archive"))])
        XCTAssertEqual(batch?.count, 2)
        let flags = try await store.flags(of: a)
        XCTAssertEqual(flags, MessageFlags(seen: true, flagged: true))
        let shown = try await inbox(store)
        XCTAssertEqual(shown, ["a"])
        let archive = try await store.summaries(account: account, mailbox: "Archive").map(\.id)
        XCTAssertEqual(archive, [b])
        let unread = try await store.unreadCount(account: account, mailbox: "INBOX")
        XCTAssertEqual(unread, 0)
        let pending = try await store.pendingActions(account: account)
        XCTAssertEqual(pending.map(\.kind), [.seen, .flagged, .move])
        XCTAssertEqual(pending.first?.base, false, "the provider's value when the person acted")
        let provider = try await store.providerFlags(of: a, account: account)
        XCTAssertEqual(provider, MessageFlags(), "the provider's state is untouched until it confirms")
        // A change that is already so is not queued.
        let none = try await store.perform([MailChange(a, .setSeen(true)), MailChange(b, .move(from: "INBOX", to: "Trash"))])
        XCTAssertNil(none)
    }

    func testQueuedChangesSurviveSyncWritesRebuildsAndAReopen() async throws {
        var store = try await MailStore.open(locations)
        let a = try await synced(store, "a", uid: 1)
        try await store.perform([MailChange(a, .setFlagged(true)), MailChange(a, .move(from: "INBOX", to: "Archive"))])

        // The sync writes the provider's (older) state and re-records the location.
        try await store.setFlags([a: MailMessageFlags()], account: account)
        try await store.record(location("INBOX", 1), for: a, account: account)
        var flags = try await store.flags(of: a)
        XCTAssertTrue(flags.flagged)
        var shown = try await inbox(store)
        XCTAssertEqual(shown, [])

        try await store.rebuildIndex()
        shown = try await inbox(store)
        XCTAssertEqual(shown, [], "a rebuilt index keeps queued changes")
        store = try await MailStore.open(locations)
        flags = try await store.flags(of: a)
        XCTAssertTrue(flags.flagged)
        let archived = try await store.effectiveMailboxes(of: a)
        XCTAssertEqual(archived, ["Archive"])
        _ = try await store.updateUIDValidity(7, mailbox: "INBOX", account: account)
        shown = try await inbox(store)
        XCTAssertEqual(shown, [])
    }

    func testUndoOfQueuedRowsShowsTheOldStateAndMarksNothingSent() async throws {
        let store = try await MailStore.open(locations)
        let a = try await synced(store, "a", uid: 1)
        let batch = try await XCTUnwrapAsync(await store.perform([MailChange(a, .setSeen(true)), MailChange(a, .move(from: "INBOX", to: "Trash"))]))
        let undo = try await XCTUnwrapAsync(await store.undo(batch))
        let flags = try await store.flags(of: a)
        XCTAssertFalse(flags.seen)
        let shown = try await inbox(store)
        XCTAssertEqual(shown, ["a"])
        let mailboxes = try await store.effectiveMailboxes(of: a)
        XCTAssertEqual(mailboxes, ["INBOX"])
        // Redo is the undo of the undo.
        try await store.undo(undo)
        let redone = try await store.effectiveMailboxes(of: a)
        XCTAssertEqual(redone, ["Trash"])
    }

    func testTheProviderWinsWhenItChangedTheSameFlagAfterThePersonActed() async throws {
        let store = try await MailStore.open(locations)
        let a = try await synced(store, "a", uid: 1)
        let b = try await synced(store, "b", uid: 2)
        try await store.perform([MailChange(a, .setSeen(true)), MailChange(b, .setFlagged(true))])
        // The sync sees: a was read elsewhere (its seen moved off the base); b got a keyword.
        try await store.setFlags([a: MailMessageFlags(seen: true, flagged: true), b: MailMessageFlags(keywords: ["$Label1"])],
                                 account: account)
        let pending = try await store.pendingActions(account: account)
        XCTAssertEqual(pending.map(\.message), [b], "a's row is overtaken; b's still applies")
        let aFlags = try await store.flags(of: a)
        XCTAssertEqual(aFlags, MessageFlags(seen: true, flagged: true), "the provider's state shows")
        let bFlags = try await store.flags(of: b)
        XCTAssertTrue(bFlags.flagged)
        let status = try await store.actionStatus(account: account)
        XCTAssertEqual(status.recentlySuperseded, 1)
    }

    func testAMessageThatLeftTheFolderAtTheProviderIsNotKeptThereByAQueuedMove() async throws {
        let store = try await MailStore.open(locations)
        let a = try await synced(store, "a", uid: 1)
        try await store.perform([MailChange(a, .move(from: "INBOX", to: "Archive"))])
        // The sync sees it gone from the inbox (deleted elsewhere).
        try await store.forget(location("INBOX", 1), account: account)
        let mailboxes = try await store.effectiveMailboxes(of: a)
        XCTAssertEqual(mailboxes, [], "not shown in Archive from a stale queued move")
        let pending = try await store.pendingActions(account: account)
        XCTAssertEqual(pending, [])
        let data = try await store.originalData(of: a)
        XCTAssertFalse(data.isEmpty, "the local file stays (MAIL-029)")
    }

    func testMessagesOnlyOnThisMacChangeLocallyWithoutAQueue() async throws {
        let store = try await MailStore.open(locations)
        let imported = try await store.ingest(SyntheticMail.plain(subject: "imported", body: "x"), account: MailAccountID("on-my-mac"))
        let batch = try await store.perform([MailChange(imported.id, .setFlagged(true))])
        XCTAssertEqual(batch?.count, 1)
        let flags = try await store.flags(of: imported.id)
        XCTAssertTrue(flags.flagged)
        let pending = try await store.pendingActions(account: MailAccountID("on-my-mac"))
        XCTAssertEqual(pending, [])
    }

    func testCompletedMovesWithoutAReportedLocationStayShownUntilTheSyncSettlesThem() async throws {
        let store = try await MailStore.open(locations)
        let a = try await synced(store, "a", uid: 1)
        try await store.perform([MailChange(a, .move(from: "INBOX", to: "Archive"))])
        let rows = try await store.pendingActions(account: account)
        let sentAt = Date()
        try await store.completeLocationActions(rows, from: [location("INBOX", 1)], to: [], awaitingLocation: true,
                                                account: account, now: sentAt)
        var mailboxes = try await store.effectiveMailboxes(of: a)
        XCTAssertEqual(mailboxes, ["Archive"], "shown where it went while the sync catches up")
        // A listing older than the move settles nothing; a newer one settles it.
        try await store.settleAwaitingActions(mailbox: "Archive", listedAt: sentAt.addingTimeInterval(-1), account: account)
        mailboxes = try await store.effectiveMailboxes(of: a)
        XCTAssertEqual(mailboxes, ["Archive"])
        try await store.record(location("Archive", 9), for: a, account: account)
        try await store.settleAwaitingActions(mailbox: "Archive", listedAt: sentAt.addingTimeInterval(1), account: account)
        let awaiting = try await store.awaitingActions(account: account)
        XCTAssertEqual(awaiting, [])
        mailboxes = try await store.effectiveMailboxes(of: a)
        XCTAssertEqual(mailboxes, ["Archive"])
    }

    /// GKM-071: the replay moved hundreds; before it completed every row, the sync saw them
    /// leave the inbox and superseded the rows still open. The provider then confirmed where
    /// each went (COPYUID): it was this move, so the rows are done and one Undo covers them all.
    func testAMoveTheSyncSawBeforeTheReplayCompletedItIsStillUndone() async throws {
        let store = try await MailStore.open(locations)
        let a = try await synced(store, "a", uid: 1)
        let b = try await synced(store, "b", uid: 2)
        let performed = try await store.perform([MailChange(a, .move(from: "INBOX", to: "Trash")),
                                                 MailChange(b, .move(from: "INBOX", to: "Trash"))])
        let batch = try XCTUnwrap(performed)
        let rows = try await store.pendingActions(account: account)
        // The MOVE went; the sync looks before the replay records it.
        try await store.forget(location("INBOX", 1), account: account)
        try await store.forget(location("INBOX", 2), account: account)
        let open = try await store.pendingActions(account: account)
        XCTAssertEqual(open, [], "the sync superseded both")
        // The replay records what the provider reported: a with its new UID, b without one.
        try await store.completeLocationActions(rows.filter { $0.message == a }, from: [location("INBOX", 1)],
                                                to: [location("Trash", 11)], awaitingLocation: true, account: account)
        try await store.completeLocationActions(rows.filter { $0.message == b }, from: [location("INBOX", 2)],
                                                to: [], awaitingLocation: true, account: account)
        let inverse = try await store.undo(batch)
        XCTAssertEqual(inverse?.count, 1, "the confirmed move is undone; an unconfirmed one stays the provider's to say")
        let back = try await store.pendingActions(account: account)
        XCTAssertEqual(back.map(\.message), [a])
        XCTAssertEqual(back.first?.source, "Trash")
        XCTAssertEqual(back.first?.target, "INBOX")
    }

    func testModSeqCheckpointResetsWithUIDValidity() async throws {
        let store = try await MailStore.open(locations)
        try await store.saveCursor(folder: "INBOX", uidValidity: 7, highestUID: 3, historyComplete: true, serverCount: 3, account: account)
        try await store.saveHighestModSeq(42, folder: "INBOX", uidValidity: 7, account: account)
        var value = try await store.highestModSeq(folder: "INBOX", uidValidity: 7, account: account)
        XCTAssertEqual(value, 42)
        try await store.saveCursor(folder: "INBOX", uidValidity: 7, highestUID: 4, historyComplete: true, serverCount: 4, account: account)
        value = try await store.highestModSeq(folder: "INBOX", uidValidity: 7, account: account)
        XCTAssertEqual(value, 42, "a new cursor at the same UIDVALIDITY keeps it")
        try await store.saveCursor(folder: "INBOX", uidValidity: 8, highestUID: 1, historyComplete: false, serverCount: 1, account: account)
        value = try await store.highestModSeq(folder: "INBOX", uidValidity: 8, account: account)
        XCTAssertNil(value, "a UIDVALIDITY reset voids it")
    }
}
