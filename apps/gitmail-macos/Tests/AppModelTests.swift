import XCTest
import MailCore
import MailStore

/// The app model against a real store in a temporary folder: no fakes.
@MainActor
final class AppModelTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let work = MailAccountID("work")
    private let home = MailAccountID("home")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gitmail-app-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAnEmptyFolderOpensToTheEmptyState() async {
        let model = AppModel(locations: locations)
        XCTAssertEqual(model.phase, .opening)
        await model.open()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.accounts, [])
        XCTAssertEqual(model.messages, [])
        XCTAssertEqual(model.mailFolder, locations.mailFolder)
    }

    func testAStoreThatCannotOpenSaysWhy() async {
        let bad = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Mail/state"))
        let model = AppModel(locations: bad)
        await model.open()
        guard case .failed(let reason) = model.phase else { return XCTFail("expected failure, got \(model.phase)") }
        XCTAssertTrue(reason.contains("outside the mail folder"), reason)
    }

    func testListsFiltersSearchesAndOpensStoredMail() async throws {
        try await seed()
        let model = AppModel(locations: locations)
        await model.open()
        XCTAssertFalse(model.isEmpty)
        XCTAssertEqual(model.accounts.map(\.displayName), ["Home", "Work"])
        XCTAssertEqual(model.totalCount, 3)
        XCTAssertEqual(model.messages.map(\.subject), ["Quarterly numbers", "Dinner on Friday", "Old receipt"], "newest first")

        await model.select(.account(work))
        XCTAssertEqual(model.selectedAccount?.id, work)
        XCTAssertEqual(model.messages.map(\.subject), ["Quarterly numbers", "Old receipt"])

        await model.search("receipt")
        XCTAssertTrue(model.isSearching)
        XCTAssertEqual(model.messages.map(\.subject), ["Old receipt"])

        let id = try XCTUnwrap(model.messages.first?.id)
        await model.selectMessage(id)
        XCTAssertEqual(model.openMessage?.front.id, id)
        XCTAssertEqual(model.openMessage?.textBody, "Paid in full.\n")

        // A search that no longer includes the open message closes it.
        await model.search("quarterly")
        XCTAssertNil(model.selectedMessageID)
        XCTAssertNil(model.openMessage)

        await model.search("")
        await model.select(.allMail)
        XCTAssertEqual(model.messages.count, 3)
    }

    func testRebuildingTheIndexKeepsTheList() async throws {
        try await seed()
        let model = AppModel(locations: locations)
        await model.open()
        let before = model.messages
        await model.rebuildIndex()
        XCTAssertNil(model.actionError)
        XCTAssertEqual(model.messages, before)
    }

    private func seed() async throws {
        let store = try await MailStore.open(locations)
        try await store.save(MailAccount(id: work, displayName: "Work", address: "ada@example.com"))
        try await store.save(MailAccount(id: home, displayName: "Home", address: "ada@example.org"))
        try await store.ingest(eml(subject: "Old receipt", date: "Mon, 2 Mar 2026 09:00:00 +0000", body: "Paid in full."), account: work)
        try await store.ingest(eml(subject: "Quarterly numbers", date: "Tue, 24 Nov 2026 09:00:00 +0000", body: "See the numbers."), account: work)
        try await store.ingest(eml(subject: "Dinner on Friday", date: "Mon, 23 Nov 2026 18:00:00 +0000", body: "Shall we?"), account: home)
    }

    private func eml(subject: String, date: String, body: String) -> Data {
        Data("From: Bo <bo@example.net>\r\nTo: ada@example.com\r\nSubject: \(subject)\r\nDate: \(date)\r\n\r\n\(body)\r\n".utf8)
    }
}
