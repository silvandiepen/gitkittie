import XCTest
import MailCore
import MailStore

/// Make Task and message links in the app model (GKM-033, MAIL-131, MAIL-132): the URL that asks
/// GitKittie Tasks for a task carries the subject, who and when, and a link back, never the
/// message's text; a `gitkittie-mail://` link opens its conversation, also when it launched the
/// app, and still does after the mail was downloaded again. A real store in a temporary folder.
@MainActor
final class MessageLinkAppTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let work = MailAccountID("work")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm033-app-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static func eml(from: String, subject: String, date: String = "Thu, 26 Nov 2026 09:30:00 +0000",
                            messageID: String?, body: String) -> Data {
        var headers = ["From: \(from)", "To: me@example.org", "Subject: \(subject)", "Date: \(date)"]
        if let messageID { headers.append("Message-ID: <\(messageID)>") }
        headers += ["MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8"]
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + body + "\r\n").utf8)
    }

    private func seed(_ locations: StoreLocations) async throws -> MailMessageID {
        let store = try await MailStore.open(locations)
        try await store.save(MailAccount(id: work, displayName: "Work", address: "me@example.org"))
        _ = try await store.ingest(Self.eml(from: "Bo <bo@example.net>", subject: "Lunch?", messageID: "lunch@example.net",
                                            body: "Noon?"), account: work)
        return try await store.ingest(Self.eml(from: "Ada Lovelace <ada@example.com>", subject: "Invoice 114 & the + sign",
                                               messageID: "inv-114@example.com",
                                               body: "The secret total is 1,250 euro."), account: work).id
    }

    private func opened(_ locations: StoreLocations) async -> AppModel {
        let model = AppModel(locations: locations)
        await model.open()
        XCTAssertEqual(model.phase, .ready)
        return model
    }

    // MARK: Make Task

    /// The exact URL Tasks reads (`NewTaskRequest` in GitKanbanKit parses this same shape): the
    /// subject as the title; who, the day and the link as the description; nothing of the text.
    func testMakeTaskAsksTasksWithTheSubjectWhoWhenAndTheLinkOnly() async throws {
        let id = try await seed(locations)
        let model = await opened(locations)
        let made = await model.taskHandoff(for: id, timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US_POSIX"))
        let handoff = try XCTUnwrap(made)
        let found = await model.link(to: id)
        let link = try XCTUnwrap(found)
        XCTAssertEqual(handoff.title, "Invoice 114 & the + sign")
        XCTAssertEqual(handoff.body, "From Ada Lovelace, Nov 26, 2026.\n\n[Open in Mail](\(link.url.absoluteString))")
        XCTAssertFalse(handoff.body.contains("1,250"), "never the message's text")
        XCTAssertFalse(handoff.body.contains("ada@example.com"), "a name, when there is one, not the address")

        let url = handoff.url
        XCTAssertEqual(url.scheme, "gitkittie-tasks")
        XCTAssertEqual(url.host, "new")
        XCTAssertFalse(url.absoluteString.contains("+"), "a + is written %2B so no decoder reads a space")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.map(\.name), ["title", "body"])
        XCTAssertEqual(items.first { $0.name == "title" }?.value, handoff.title)
        XCTAssertEqual(items.first { $0.name == "body" }?.value, handoff.body)
    }

    func testMakeTaskForAMessageThatIsGoneSaysSo() async throws {
        _ = try await seed(locations)
        let model = await opened(locations)
        let handoff = await model.taskHandoff(for: MailMessageID())
        XCTAssertNil(handoff)
        XCTAssertNotNil(model.actionError)
    }

    func testWithoutASubjectTheTitleSaysWhoItIsFrom() throws {
        let link = MessageLink(account: work, messageID: "x@example.com", fingerprint: "")
        let named = TaskHandoff(subject: "  ", from: MailAddress(name: "Bo", address: "bo@example.net"), date: .now, link: link)
        XCTAssertEqual(named.title, "Message from Bo")
        let anonymous = TaskHandoff(subject: nil, from: nil, date: .now, link: link)
        XCTAssertEqual(anonymous.title, "Message")
        XCTAssertTrue(anonymous.body.hasPrefix("Mail, "))
    }

    // MARK: Opening a link

    /// A link opens its conversation from wherever the window is.
    func testALinkOpensItsConversation() async throws {
        let id = try await seed(locations)
        let model = await opened(locations)
        let found = await model.link(to: id)
        let link = try XCTUnwrap(found)
        await model.select(.drafts)

        let opened = await model.openLink(link.url)
        XCTAssertTrue(opened)
        XCTAssertEqual(model.browser.openThread?.messages.filter(\.isExpanded).map(\.id), [id])
        XCTAssertEqual(model.externalOpens, 1)
    }

    /// The link launched the app: it waits for the store and then opens.
    func testALinkThatLaunchedTheAppOpensOnceTheStoreIsOpen() async throws {
        let id = try await seed(locations)
        let found = try await MailStore.open(locations).link(to: id)
        let link = try XCTUnwrap(found)
        let model = AppModel(locations: locations)
        await model.openLink(link.url)
        XCTAssertNil(model.browser.openThread, "nothing to show before the store is open")
        await model.open()
        XCTAssertEqual(model.browser.openThread?.messages.filter(\.isExpanded).map(\.id), [id])
        XCTAssertEqual(model.externalOpens, 1)
    }

    /// The round trip across a fresh download: a link copied from one mail folder opens the
    /// same message in another that downloaded it again under new local ids.
    func testALinkStillOpensAfterTheMailIsDownloadedAgain() async throws {
        let id = try await seed(locations)
        let found = try await MailStore.open(locations).link(to: id)
        let link = try XCTUnwrap(found)

        let elsewhere = StoreLocations(mailFolder: root.appendingPathComponent("Again/Mail"),
                                       deviceFolder: root.appendingPathComponent("Again/Support/Mail"))
        let newID = try await seed(elsewhere)
        XCTAssertNotEqual(newID, id)
        let model = await opened(elsewhere)
        await model.openLink(link.url)
        XCTAssertEqual(model.browser.openThread?.messages.filter(\.isExpanded).map(\.id), [newID])
    }

    func testALinkToMailNotHereOrNotALinkSaysSo() async throws {
        _ = try await seed(locations)
        let model = await opened(locations)
        let missing = MessageLink(account: work, messageID: "never@example.com", fingerprint: "")
        await model.openLink(missing.url)
        XCTAssertNil(model.browser.openThread)
        XCTAssertNotNil(model.actionError)

        model.actionError = nil
        let opened = await model.openLink(URL(string: "gitkittie-mail://message/work/../../etc")!)
        XCTAssertFalse(opened)
        XCTAssertNotNil(model.actionError)
    }
}
