import XCTest
import MailCore
import MailStore

/// Mail opens where it was left (MAIL-107, GKM-067): the sidebar's view and the open
/// conversation are saved on this device as they change and come back when the app model
/// opens the store again; a view that is gone falls back to Focused, a conversation that is
/// gone to the list. A real store in a temporary folder, two app models in a row, as a quit and
/// a relaunch.
@MainActor
final class LastPlaceTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let work = MailAccountID("work")
    private let home = MailAccountID("home")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm090-place-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func reopened() async -> AppModel {
        let model = AppModel(locations: locations)
        await model.open()
        XCTAssertEqual(model.phase, .ready)
        return model
    }

    func testAFreshFolderOpensInFocused() async throws {
        try await seed()
        let model = await reopened()
        XCTAssertEqual(model.selection, .category(.focused))
        XCTAssertNil(model.browser.openThread)
    }

    func testTheFolderAndTheConversationComeBack() async throws {
        try await seed()
        let first = await reopened()
        await first.select(.folder(work, "INBOX"))
        let row = try XCTUnwrap(first.browser.rows.first { $0.latest.subject == "Re: Quarterly numbers" })
        await first.browser.select(row.id)
        XCTAssertEqual(first.browser.openThread?.id, row.threadID)

        let second = await reopened()
        XCTAssertEqual(second.selection, .folder(work, "INBOX"))
        XCTAssertEqual(second.browser.scope, .folder(work, "INBOX"))
        XCTAssertEqual(second.browser.openThread?.id, row.threadID, "the conversation that was open")
        XCTAssertEqual(second.browser.selectedRowID, row.id, "selected in the list")
    }

    func testClosingTheConversationIsRememberedToo() async throws {
        try await seed()
        let first = await reopened()
        await first.select(.account(home))
        let row = try XCTUnwrap(first.browser.rows.first)
        await first.browser.select(row.id)
        await first.browser.select(nil)

        let second = await reopened()
        XCTAssertEqual(second.selection, .account(home))
        XCTAssertNil(second.browser.openThread)
    }

    func testViewsWithoutAListComeBackWithoutAConversation() async throws {
        try await seed()
        let first = await reopened()
        await first.select(.allMail)
        await first.browser.select(try XCTUnwrap(first.browser.rows.first).id)
        await first.select(.senders)

        let second = await reopened()
        XCTAssertEqual(second.selection, .senders)
        XCTAssertNil(LastPlace.load(deviceFolder: locations.deviceFolder)?.threadID)
    }

    func testAViewThatIsGoneFallsBackToFocused() async throws {
        try await seed()
        let first = await reopened()
        let created = await first.spaces.create(name: "Trip", icon: "airplane", color: "blue")
        let space = try XCTUnwrap(created)
        await first.select(.space(space.id))
        XCTAssertEqual(LastPlace.load(deviceFolder: locations.deviceFolder)?.selection, .space(space.id))

        // The space is deleted elsewhere (spaces live in the mail folder, MAIL-042).
        let store = try await MailStore.open(locations)
        try await store.deleteSpace(space.id)

        let second = await reopened()
        XCTAssertEqual(second.selection, .category(.focused))
        XCTAssertEqual(second.browser.scope, .category(.focused))
        XCTAssertEqual(LastPlace.load(deviceFolder: locations.deviceFolder)?.selection, .category(.focused),
                       "the fallback is what is remembered now")
    }

    func testAFolderThatIsGoneFallsBackToFocused() async throws {
        try await seed()
        // Left on a folder the account no longer has: no stored mail in it, not in the sync state.
        try LastPlace(selection: .folder(work, "Projects/2025"), threadID: nil).save(deviceFolder: locations.deviceFolder)

        let model = await reopened()
        XCTAssertEqual(model.selection, .category(.focused))
    }

    func testAConversationThatIsGoneLeavesTheViewWithoutOne() async throws {
        try await seed()
        let first = await reopened()
        await first.select(.allMail)
        let row = try XCTUnwrap(first.browser.rows.first { $0.latest.subject == "Dinner on Friday" })
        await first.browser.select(row.id)

        // The conversation leaves All Mail before the next launch: its account's mail is removed.
        let store = try await MailStore.open(locations)
        try await store.disconnectAccount(home, mail: .remove)

        let second = await reopened()
        XCTAssertEqual(second.selection, .allMail, "the view is still there")
        XCTAssertNil(second.browser.openThread, "the conversation is not")
        XCTAssertNil(second.browser.selectedRowID)
    }

    /// Left on a conversation older than the list's first page (GKM-112): the list loads pages
    /// up to it and selects its row, as a notification does (GKM-085). On iPhone the reader is
    /// pushed by the list's selection; without a row the app opened on the list.
    func testAConversationBelowTheFirstPageComesBackSelected() async throws {
        try await seed()
        let store = try await MailStore.open(locations)
        for index in 0..<MailBrowser.pageSize {
            try await store.ingest(eml(subject: "Note \(index)", date: "Wed, 25 Nov 2026 \(String(format: "%02d:%02d", index / 60, index % 60)):00 +0000",
                                       id: "note-\(index)@example.org"), account: home)
        }
        let first = await reopened()
        await first.select(.allMail)
        XCTAssertFalse(first.browser.rows.contains { $0.latest.subject == "Dinner on Friday" }, "the first page leaves it out")
        while first.browser.canLoadMore, !first.browser.rows.contains(where: { $0.latest.subject == "Dinner on Friday" }) {
            await first.browser.loadMore()
        }
        let row = try XCTUnwrap(first.browser.rows.first { $0.latest.subject == "Dinner on Friday" })
        await first.browser.select(row.id)
        XCTAssertEqual(LastPlace.load(deviceFolder: locations.deviceFolder)?.threadID, row.threadID)

        let second = await reopened()
        XCTAssertEqual(second.selection, .allMail)
        XCTAssertEqual(second.browser.openThread?.id, row.threadID, "the conversation that was open")
        XCTAssertEqual(second.browser.selectedRowID, row.id, "selected in the list")

        // A refresh of the list (a sync, a change) keeps the row, the selection and the conversation.
        await second.browser.reload()
        XCTAssertEqual(second.browser.selectedRowID, row.id)
        XCTAssertEqual(second.browser.openThread?.id, row.threadID)
    }

    func testAnUnreadableFileOpensInFocused() async throws {
        try await seed()
        let url = LastPlace.url(deviceFolder: locations.deviceFolder)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)

        let model = await reopened()
        XCTAssertEqual(model.selection, .category(.focused))
    }

    // MARK: Fixtures

    private func seed() async throws {
        let store = try await MailStore.open(locations)
        try await store.save(MailAccount(id: work, displayName: "Work", address: "ada@example.com"))
        try await store.save(MailAccount(id: home, displayName: "Home", address: "ada@example.org"))
        try await store.ingest(eml(subject: "Quarterly numbers", date: "Tue, 24 Nov 2026 09:00:00 +0000", id: "q@example.com"),
                               account: work, remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 1))
        try await store.ingest(eml(subject: "Re: Quarterly numbers", date: "Tue, 24 Nov 2026 11:00:00 +0000", id: "r@example.com",
                                   inReplyTo: "q@example.com"),
                               account: work, remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 2))
        try await store.ingest(eml(subject: "Dinner on Friday", date: "Mon, 23 Nov 2026 18:00:00 +0000", id: "d@example.org"), account: home)
    }

    private func eml(subject: String, date: String, id: String, inReplyTo: String? = nil) -> Data {
        var headers = "From: Bo <bo@example.net>\r\nTo: ada@example.com\r\nSubject: \(subject)\r\nDate: \(date)\r\nMessage-ID: <\(id)>\r\n"
        if let inReplyTo { headers += "In-Reply-To: <\(inReplyTo)>\r\n" }
        return Data((headers + "\r\n\(subject).\r\n").utf8)
    }
}
