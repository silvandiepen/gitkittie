import XCTest
import MailCore
import MailStore

/// Spaces, the attachment library and export through the app model, against a real store in a
/// temporary folder (GKM-022, GKM-023). No fakes.
@MainActor
final class SpacesAppTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let work = MailAccountID("work")
    private let home = MailAccountID("home")
    private let pdf = Data("%PDF-1.4 synthetic site plan".utf8)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gitmail-spaces-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func seed() async throws {
        let store = try await MailStore.open(locations)
        try await store.save(MailAccount(id: work, displayName: "Work", address: "ada@example.com"))
        try await store.save(MailAccount(id: home, displayName: "Home", address: "ada@example.org"))
        try await store.ingest(eml(subject: "Site plan", date: "Tue, 24 Nov 2026 09:00:00 +0000", id: "plan@example.com",
                                   from: "Studio <hello@studio.example.com>", attachment: pdf), account: work)
        try await store.ingest(eml(subject: "Re: Site plan", date: "Tue, 24 Nov 2026 11:00:00 +0000", id: "re@example.org",
                                   inReplyTo: "plan@example.com", from: "Bo <bo@example.org>"), account: work)
        try await store.ingest(eml(subject: "Studio newsletter", date: "Mon, 23 Nov 2026 18:00:00 +0000", id: "news@example.com",
                                   from: "Studio <news@studio.example.com>"), account: home)
        try await store.ingest(eml(subject: "Dinner", date: "Sun, 22 Nov 2026 18:00:00 +0000", id: "dinner@example.net",
                                   from: "Cy <cy@example.net>"), account: home)
    }

    private func eml(subject: String, date: String, id: String, inReplyTo: String? = nil, from: String, attachment: Data? = nil) -> Data {
        var headers = "From: \(from)\r\nTo: ada@example.com\r\nSubject: \(subject)\r\nDate: \(date)\r\nMessage-ID: <\(id)>\r\n"
        if let inReplyTo { headers += "In-Reply-To: <\(inReplyTo)>\r\n" }
        guard let attachment else { return Data((headers + "\r\nHello.\r\n").utf8) }
        return Data((headers + """
            Content-Type: multipart/mixed; boundary="b"\r
            \r
            --b\r
            Content-Type: text/plain\r
            \r
            Plan attached.\r
            --b\r
            Content-Type: application/pdf; name="plan.pdf"\r
            Content-Disposition: attachment; filename="plan.pdf"\r
            Content-Transfer-Encoding: base64\r
            \r
            \(attachment.base64EncodedString())\r
            --b--\r

            """).utf8)
    }

    private func subjects(_ model: AppModel) -> [String] { model.browser.rows.map { $0.latest.subject ?? "" } }

    // MARK: Spaces

    func testASpaceViewListsItsConversationsAcrossAccounts() async throws {
        try await seed()
        let model = AppModel(locations: locations)
        await model.open()
        let created = await model.spaces.create(name: "Studio", icon: "paintbrush.fill", color: "purple",
                                                rules: [SpaceRule(domain: "studio.example.com")])
        let space = try XCTUnwrap(created)
        XCTAssertEqual(model.spaces.spaces.map(\.name), ["Studio"])
        XCTAssertEqual(model.spaces.counts[space.id]?.messages, 2, "the rule filled it from both accounts")

        await model.select(.space(space.id))
        XCTAssertEqual(model.browser.scope, .space(space.id))
        XCTAssertEqual(subjects(model), ["Site plan", "Studio newsletter"], "a conversation shows by its newest message in the space")
        XCTAssertEqual(model.browser.rows.first?.messageCount, 1, "counts are within the space")

        // The whole conversation by hand, then one taken out.
        let thread = try XCTUnwrap(model.browser.rows.first?.threadID)
        let added = await model.spaces.add(threads: [thread], to: space.id)
        XCTAssertEqual(added, 1)
        await model.browser.reload()
        XCTAssertEqual(model.browser.rows.first?.messageCount, 2)
        XCTAssertEqual(model.browser.rows.first?.latest.subject, "Re: Site plan")
        let removed = await model.spaces.remove(threads: [thread], from: space.id)
        XCTAssertEqual(removed, 2)
        await model.browser.reload()
        XCTAssertEqual(subjects(model), ["Studio newsletter"])

        // A sync bringing new matching mail fills the space; what was taken out stays out.
        let store = try XCTUnwrap(model.mailStore)
        try await store.ingest(eml(subject: "Moodboard", date: "Wed, 25 Nov 2026 08:00:00 +0000", id: "mood@example.com",
                                   from: "Studio <hello@studio.example.com>"), account: work)
        await model.refreshAfterSync()
        XCTAssertEqual(subjects(model), ["Moodboard", "Studio newsletter"])
    }

    func testMarkingSeveralConversationsAndDeletingASpace() async throws {
        try await seed()
        let model = AppModel(locations: locations)
        await model.open()
        let browser = model.browser
        XCTAssertEqual(subjects(model), ["Re: Site plan", "Studio newsletter", "Dinner"])
        await browser.select(browser.rows[0].id)
        browser.extendMark(to: browser.rows[2].id)
        XCTAssertEqual(browser.markedRowIDs.count, 3)
        browser.toggleMark(browser.rows[1].id)
        XCTAssertEqual(browser.threadIDs(actingOn: nil).count, 2)
        XCTAssertEqual(browser.threadIDs(actingOn: browser.rows[1].id).count, 1, "a row that is not marked acts alone")

        let spaceValue = await model.spaces.create(name: "Picked", icon: "star.fill", color: "yellow")
        let space = try XCTUnwrap(spaceValue)
        let added = await model.spaces.add(threads: browser.threadIDs(actingOn: nil), to: space.id)
        XCTAssertEqual(added, 3, "two conversations: the site plan (two messages) and dinner")
        browser.clearMarks()

        await model.select(.space(space.id))
        XCTAssertEqual(subjects(model), ["Re: Site plan", "Dinner"])
        let mailBefore = try await model.mailStore!.messageCount()

        await model.select(.allMail)
        await model.spaces.delete(space.id)
        XCTAssertTrue(model.spaces.spaces.isEmpty)
        let mailAfter = try await model.mailStore!.messageCount()
        XCTAssertEqual(mailAfter, mailBefore, "deleting a space deletes no mail")
        XCTAssertNil(model.spaces.actionError)
    }

    func testMovingSpacesReordersThem() async throws {
        try await seed()
        let model = AppModel(locations: locations)
        await model.open()
        for name in ["A", "B", "C"] { await model.spaces.create(name: name, icon: "folder.fill", color: "blue") }
        await model.spaces.move(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(model.spaces.spaces.map(\.name), ["C", "A", "B"])
        await model.spaces.move(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(model.spaces.spaces.map(\.name), ["A", "B", "C"])
    }

    // MARK: The attachment library

    func testTheLibraryFiltersPreviewsSavesAndShowsTheMessage() async throws {
        try await seed()
        let model = AppModel(locations: locations)
        await model.open()
        let library = model.library
        await model.select(.attachments)
        await library.show(in: nil)
        XCTAssertEqual(library.items.map(\.reference.fileName), ["plan.pdf"])
        XCTAssertEqual(library.totalBytes, pdf.count)

        await library.setFilters(AttachmentFilters(kind: .image))
        XCTAssertTrue(library.items.isEmpty)
        await library.setFilters(AttachmentFilters(sender: "studio"))
        XCTAssertEqual(library.items.count, 1)

        let item = try XCTUnwrap(library.items.first)
        await library.select(item.id)
        XCTAssertEqual(model.browser.openThread?.messages.first { $0.isExpanded }?.id, item.message, "Show Message opens it in the reader")

        let preview = try await library.previewFile(for: item)
        XCTAssertEqual(try Data(contentsOf: preview), pdf)
        XCTAssertTrue(preview.path.hasPrefix(locations.deviceFolder.path), "Quick Look reads a private copy, never the blob")

        let saved = root.appendingPathComponent(library.suggestedFileName(for: item))
        try await library.save(item, to: saved)
        XCTAssertEqual(try Data(contentsOf: saved), pdf)
        let quarantine = try saved.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        XCTAssertNotNil(quarantine, "a saved attachment is marked as downloaded")

        // Inside a space, only the space's attachments.
        let spaceValue = await model.spaces.create(name: "Empty", icon: "folder.fill", color: "gray")
        let space = try XCTUnwrap(spaceValue)
        await library.setFilters(AttachmentFilters())
        await library.show(in: space.id)
        XCTAssertTrue(library.items.isEmpty)
    }

    // MARK: Export

    func testExportingAConversationWritesOriginalsAndReports() async throws {
        try await seed()
        let model = AppModel(locations: locations)
        await model.open()
        let destination = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let thread = try XCTUnwrap(model.browser.rows.first?.threadID)
        let reportValue = await model.export(.threads([thread]), to: destination)
        let report = try XCTUnwrap(reportValue)
        XCTAssertEqual(report.messages, 2)
        XCTAssertEqual(report.attachments, 1)
        XCTAssertEqual(model.exportReport, report)
        XCTAssertTrue(report.summary.hasPrefix("2 messages exported"))

        let emls = FileManager.default.enumerator(at: report.folder, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "eml" }
        XCTAssertEqual(emls.count, 2)
        let store = try XCTUnwrap(model.mailStore)
        for url in emls {
            let id = try XCTUnwrap(MailMessageID(url.deletingPathExtension().lastPathComponent))
            let original = try await store.originalData(of: id)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }

        let missing = await model.export(.threads([thread]), to: root.appendingPathComponent("Nope"))
        XCTAssertNil(missing)
        XCTAssertNotNil(model.actionError)
    }
}
