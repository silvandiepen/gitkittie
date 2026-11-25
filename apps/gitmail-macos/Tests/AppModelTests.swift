import XCTest
import MailCore
import MailExtraction
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
        XCTAssertEqual(model.browser.rows, [])
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
        await model.select(.allMail) // the window opens on Focused (GKM-018); these tests are about All Mail
        let browser = model.browser
        XCTAssertFalse(model.isEmpty)
        XCTAssertEqual(model.accounts.map(\.displayName), ["Home", "Work"])
        XCTAssertEqual(model.totalCount, 4)
        XCTAssertEqual(subjects(browser), ["Re: Quarterly numbers", "Dinner on Friday", "Old receipt"], "threads, newest activity first")
        XCTAssertEqual(browser.rows.first?.messageCount, 2)
        XCTAssertEqual(model.folders[work], ["INBOX"])

        await model.select(.account(work))
        XCTAssertEqual(model.selectedAccount?.id, work)
        XCTAssertEqual(subjects(browser), ["Re: Quarterly numbers", "Old receipt"])

        await model.select(.folder(work, "INBOX"))
        XCTAssertEqual(subjects(browser), ["Re: Quarterly numbers"])

        await model.select(.account(work))
        await browser.search("receipt")
        XCTAssertTrue(browser.isSearching)
        XCTAssertEqual(subjects(browser), ["Old receipt"])

        // Opening a result opens its conversation, marks it read, and shows the plain text.
        let rowID = try XCTUnwrap(browser.rows.first?.id)
        await browser.select(rowID)
        let thread = try XCTUnwrap(browser.openThread)
        XCTAssertEqual(thread.messages.count, 1)
        XCTAssertTrue(thread.messages[0].isExpanded)
        guard case .plain(let text) = thread.messages[0].content?.body else { return XCTFail("expected plain text") }
        XCTAssertEqual(text, "Paid in full.\n")
        XCTAssertEqual(browser.rows.first?.isUnread, false, "opening marks it read")

        // A search that no longer includes the open conversation closes it.
        await browser.search("quarterly")
        XCTAssertNil(browser.selectedRowID)
        XCTAssertNil(browser.openThread)

        await browser.search("")
        await model.select(.allMail)
        XCTAssertEqual(browser.rows.count, 3)
    }

    func testTypingIntoSearchKeepsEveryKeystroke() async throws {
        try await seed()
        let model = AppModel(locations: locations)
        await model.open()
        await model.select(.allMail)
        let browser = model.browser

        // A search field writes each keystroke and reads the text straight back.
        var last: Task<Void, Never>?
        for prefix in ["r", "re", "rec", "rece", "recei", "receip", "receipt"] {
            last = browser.typeSearch(prefix) ?? last
            XCTAssertEqual(browser.searchText, prefix, "the field must read back what was typed")
        }
        await last?.value
        XCTAssertEqual(subjects(browser), ["Old receipt"])
        XCTAssertNil(browser.typeSearch("receipt"), "the same text runs nothing")
    }

    func testAThreadOpensWithTheNewestExpandedAndOlderOnesOnClick() async throws {
        try await seed()
        let model = AppModel(locations: locations)
        await model.open()
        await model.select(.allMail) // the window opens on Focused (GKM-018); these tests are about All Mail
        let browser = model.browser
        await browser.select(try XCTUnwrap(browser.rows.first?.id))
        var thread = try XCTUnwrap(browser.openThread)
        XCTAssertEqual(thread.messages.map(\.summary.subject), ["Quarterly numbers", "Re: Quarterly numbers"], "oldest first")
        XCTAssertEqual(thread.messages.map(\.isExpanded), [false, true])
        XCTAssertNil(thread.messages[0].content, "collapsed messages are not read until asked")
        XCTAssertEqual(thread.messages.map(\.summary.isUnread), [false, false], "the whole conversation is read once opened")

        await browser.toggleExpanded(thread.messages[0].id)
        thread = try XCTUnwrap(browser.openThread)
        XCTAssertTrue(thread.messages[0].isExpanded)
        XCTAssertNotNil(thread.messages[0].content)

        await browser.setFlagged(true, for: thread.messages[1].id)
        XCTAssertEqual(browser.rows.first?.isFlagged, true)
        await browser.setUnread(true, for: thread.messages[1].id)
        XCTAssertEqual(browser.rows.first?.isUnread, true)
    }

    func testKeyboardMovesTheSelection() async throws {
        try await seed()
        let model = AppModel(locations: locations)
        await model.open()
        await model.select(.allMail) // the window opens on Focused (GKM-018); these tests are about All Mail
        let browser = model.browser
        await browser.selectNext()
        XCTAssertEqual(browser.selectedRowID, browser.rows[0].id)
        await browser.selectNext()
        await browser.selectNext()
        await browser.selectNext()
        XCTAssertEqual(browser.selectedRowID, browser.rows[2].id, "stops at the end")
        await browser.selectPrevious()
        XCTAssertEqual(browser.selectedRowID, browser.rows[1].id)
        XCTAssertEqual(browser.openThread?.id, browser.rows[1].threadID)
    }

    func testFilterChipsAndSearchSyntaxCombine() async throws {
        try await seed()
        let model = AppModel(locations: locations)
        await model.open()
        await model.select(.allMail) // the window opens on Focused (GKM-018); these tests are about All Mail
        let browser = model.browser
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        browser.calendar = calendar
        browser.now = { Date(timeIntervalSince1970: 1_795_600_000) } // 2026-11-25

        await browser.setFilters(SearchFilters(date: .week))
        XCTAssertEqual(subjects(browser), ["Re: Quarterly numbers", "Quarterly numbers", "Dinner on Friday"])
        await browser.setFilters(SearchFilters(account: home, date: .week))
        XCTAssertEqual(subjects(browser), ["Dinner on Friday"])
        await browser.setFilters(SearchFilters(participant: "cy"))
        XCTAssertEqual(subjects(browser), ["Re: Quarterly numbers"])
        await browser.search("from:bo numbers")
        XCTAssertEqual(subjects(browser), [], "chips and syntax both narrow")
        await browser.setFilters(SearchFilters(unreadOnly: true))
        XCTAssertEqual(subjects(browser), ["Quarterly numbers"])
        XCTAssertEqual(browser.query.text, "numbers")
        XCTAssertEqual(browser.query.participant, "bo")
    }

    func testRemoteImagesArePerSenderAndNeverForASpoofedSender() async throws {
        let store = try await MailStore.open(locations)
        let honest = Data("""
            From: News <news@example.com>\r
            To: ada@example.com\r
            Subject: Photos\r
            Date: Tue, 24 Nov 2026 09:00:00 +0000\r
            Content-Type: text/html\r
            \r
            <p>Look</p><img src="https://images.example.com/a.png" width="300">\r

            """.utf8)
        let spoofed = Data(String(decoding: honest, as: UTF8.self)
            .replacingOccurrences(of: "From: News <news@example.com>", with: "From: \"service@bank.example.org\" <news@example.com>")
            .replacingOccurrences(of: "Subject: Photos", with: "Subject: Spoof").utf8)
        try await store.ingest(honest, account: work)
        try await store.ingest(spoofed, account: work)

        let model = AppModel(locations: locations)
        await model.open()
        await model.select(.allMail) // the window opens on Focused (GKM-018); these tests are about All Mail
        let browser = model.browser
        let photos = try XCTUnwrap(browser.rows.first { $0.latest.subject == "Photos" })
        await browser.select(photos.id)
        var message = try XCTUnwrap(browser.openThread?.messages.last)
        XCTAssertFalse(message.remoteImagesLoaded, "blocked by default")
        await browser.loadRemoteImages(for: message.id, alwaysForSender: true)
        message = try XCTUnwrap(browser.openThread?.messages.last)
        XCTAssertTrue(message.remoteImagesLoaded)

        // Same address, but the display name carries another address: the choice is ignored.
        let spoof = try XCTUnwrap(browser.rows.first { $0.latest.subject == "Spoof" })
        await browser.select(spoof.id)
        let spoofMessage = try XCTUnwrap(browser.openThread?.messages.last)
        XCTAssertFalse(spoofMessage.content?.sender.warnings.isEmpty ?? true)
        XCTAssertFalse(spoofMessage.remoteImagesLoaded)

        // Remembered across launches.
        let reopened = AppModel(locations: locations)
        await reopened.open()
        let again = try XCTUnwrap(reopened.browser.rows.first { $0.latest.subject == "Photos" })
        await reopened.browser.select(again.id)
        XCTAssertEqual(reopened.browser.openThread?.messages.last?.remoteImagesLoaded, true)
    }

    func testImportingEMLFilesAndFolders() async throws {
        let folder = root.appendingPathComponent("Export/Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try eml(subject: "One", date: "Mon, 2 Mar 2026 09:00:00 +0000", body: "First").write(to: folder.appendingPathComponent("one.eml"))
        try eml(subject: "Two", date: "Tue, 3 Mar 2026 09:00:00 +0000", body: "Second").write(to: folder.deletingLastPathComponent().appendingPathComponent("two.EML"))
        try Data("not mail at all".utf8).write(to: folder.appendingPathComponent("broken.eml"))
        try Data("ignored".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.eml"), withDestinationURL: folder.appendingPathComponent("one.eml"))

        let model = AppModel(locations: locations)
        await model.open()
        await model.select(.allMail) // the window opens on Focused (GKM-018); these tests are about All Mail
        await model.importMessages(from: [root.appendingPathComponent("Export")])
        XCTAssertEqual(model.importReport, ImportReport(imported: 2, duplicates: 0, skipped: ["broken.eml"]))
        XCTAssertEqual(model.accounts.map(\.displayName), ["On My Mac"])
        XCTAssertEqual(subjects(model.browser), ["Two", "One"])
        XCTAssertEqual(model.browser.rows.map(\.isUnread), [true, true], "imported mail arrives unread (MAIL-073)")

        await model.importMessages(from: [folder.appendingPathComponent("one.eml")])
        XCTAssertEqual(model.importReport, ImportReport(imported: 0, duplicates: 1, skipped: []))
        XCTAssertEqual(model.totalCount, 2)
    }

    /// Attachment text through the same XPC interface and client the app uses (an anonymous
    /// listener stands in for the bundled service, which only exists inside GitMail.app).
    func testAttachmentTextIsExtractedThroughXPCAndSearchable() async throws {
        let store = try await MailStore.open(locations)
        let text = "Itinerary: train to Utrecht at 08:12, platform 5"
        try await store.ingest(attachmentMail(fileName: "itinerary.txt", mediaType: "text/plain", data: Data(text.utf8)), account: work)
        let delegate = ExtractorDelegate()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }

        let model = AppModel(locations: locations, extractor: IsolatedTextExtractor(endpoint: listener.endpoint, timeout: .seconds(10)))
        await model.open()
        await model.select(.allMail) // the window opens on Focused (GKM-018); these tests are about All Mail
        await model.waitForAttachmentText()
        await model.browser.search("utrecht platform")
        XCTAssertEqual(subjects(model.browser), ["Travel"])
    }

    func testRebuildingTheIndexKeepsTheList() async throws {
        try await seed()
        let model = AppModel(locations: locations)
        await model.open()
        await model.select(.allMail) // the window opens on Focused (GKM-018); these tests are about All Mail
        let before = model.browser.rows
        await model.rebuildIndex()
        XCTAssertNil(model.actionError)
        XCTAssertEqual(model.browser.rows, before)
    }

    // MARK: Helpers

    private func subjects(_ browser: MailBrowser) -> [String] { browser.rows.compactMap(\.latest.subject) }

    private func seed() async throws {
        let store = try await MailStore.open(locations)
        try await store.save(MailAccount(id: work, displayName: "Work", address: "ada@example.com"))
        try await store.save(MailAccount(id: home, displayName: "Home", address: "ada@example.org"))
        try await store.ingest(eml(subject: "Old receipt", date: "Mon, 2 Mar 2026 09:00:00 +0000", body: "Paid in full."), account: work)
        try await store.ingest(eml(subject: "Quarterly numbers", date: "Tue, 24 Nov 2026 09:00:00 +0000", body: "See the numbers.", id: "q@example.com"),
                               account: work, remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 1))
        try await store.ingest(eml(subject: "Re: Quarterly numbers", date: "Tue, 24 Nov 2026 11:00:00 +0000", body: "Thanks.", id: "r@example.com",
                                   inReplyTo: "q@example.com", from: "Cy <cy@example.net>"),
                               account: work, remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 2))
        try await store.ingest(eml(subject: "Dinner on Friday", date: "Mon, 23 Nov 2026 18:00:00 +0000", body: "Shall we?"), account: home)
    }

    private func eml(subject: String, date: String, body: String, id: String? = nil, inReplyTo: String? = nil,
                     from: String = "Bo <bo@example.net>") -> Data {
        var headers = "From: \(from)\r\nTo: ada@example.com\r\nSubject: \(subject)\r\nDate: \(date)\r\n"
        if let id { headers += "Message-ID: <\(id)>\r\n" }
        if let inReplyTo { headers += "In-Reply-To: <\(inReplyTo)>\r\n" }
        return Data((headers + "\r\n\(body)\r\n").utf8)
    }

    private func attachmentMail(fileName: String, mediaType: String, data: Data) -> Data {
        Data("""
            From: Rail <rail@example.com>\r
            To: ada@example.com\r
            Subject: Travel\r
            Date: Tue, 24 Nov 2026 09:00:00 +0000\r
            Content-Type: multipart/mixed; boundary="b"\r
            \r
            --b\r
            Content-Type: text/plain\r
            \r
            Your trip is attached.\r
            --b\r
            Content-Type: \(mediaType); name="\(fileName)"\r
            Content-Disposition: attachment; filename="\(fileName)"\r
            Content-Transfer-Encoding: base64\r
            \r
            \(data.base64EncodedString())\r
            --b--\r

            """.utf8)
    }
}

private final class ExtractorDelegate: NSObject, NSXPCListenerDelegate {
    let service = ExtractionService(watchdog: nil)
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: AttachmentTextExtractionXPC.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
