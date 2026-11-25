import Foundation
import MailCore
import MailIMAP
import MailMIME
import MailProvider
import MailStore
import MailSync
import NIOCore
import NIOPosix
import XCTest

/// Searching the provider for mail the history window left there (GKM-041, MAIL-081..083),
/// against the real local mail server and a real store. Each test has its own synthetic account
/// and checks that its password never reached the log.
final class ServerSearchIntegrationTests: XCTestCase {
    private var server: TestMailServer!
    private var user: TestUser!
    private var captured: CapturedLog!
    private var root: URL!
    private var store: MailStore!
    private let account = MailAccountID("search-test")
    private let windowed = SyncOptions(recentPerFolder: 1, historyDays: 30, bodyBatchMessages: 1,
                                       reconnect: ReconnectPolicy(maxAttempts: 10, initialDelay: .milliseconds(50),
                                                                  maxDelay: .milliseconds(200), jitter: 0))

    override func setUp() async throws {
        server = try await TestMailServer.require()
        user = try await server.makeUser(function: name)
        captured = CapturedLog()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm041-search-\(UUID().uuidString)", isDirectory: true)
        store = try await MailStore.open(StoreLocations(mailFolder: root.appendingPathComponent("Mail"),
                                                        deviceFolder: root.appendingPathComponent("Support/Mail")))
    }

    override func tearDown() async throws {
        if let user, let captured { captured.assertNoSecret(user.rawPassword) }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Helpers

    private func imap(port: Int? = nil) -> IMAPConnector {
        IMAPConnector(endpoint: ServerEndpoint(host: "localhost", port: port ?? server.imapsPort, security: .implicitTLS,
                                               trust: server.trust, connectTimeout: .seconds(5)),
                      credential: user.credential, log: captured.log, commandTimeout: .seconds(20))
    }

    private func searcher(limit: Int = ServerSearcher.defaultLimit, onDemandThreshold: Int? = nil, port: Int? = nil) -> ServerSearcher {
        ServerSearcher(account: account, connector: imap(port: port), store: store, onDemandThreshold: onDemandThreshold,
                       limit: limit, log: captured.log)
    }

    private func sync() async throws {
        try await SyncCoordinator(account: account, connector: imap(), store: store, options: windowed, log: captured.log).syncOnce()
    }

    private var me: MailAddress { MailAddress(name: "Ada Example", address: user.address) }

    /// Appends one message per entry (subject, days ago, sender), received that many days ago,
    /// and returns the bytes in UID order.
    @discardableResult
    private func append(_ messages: [(subject: String, daysAgo: Int, from: MailAddress?)], to folder: String = "INBOX",
                        attachment: Data? = nil) async throws -> [Data] {
        var sent: [Data] = []
        try await imap().withSession { session in
            if folder != "INBOX", !(try await session.listFolders().contains { $0.id == folder }) {
                try await session.createFolder(folder)
            }
            for entry in messages {
                let attachments = attachment.map { [OutgoingAttachment(filename: "scan.bin", mimeType: "application/octet-stream", data: $0)] } ?? []
                let raw = MIMEBuilder(from: entry.from ?? self.me, to: [self.me], subject: entry.subject,
                                      textBody: "Body of \(entry.subject)\n", attachments: attachments).build()
                _ = try await session.append(raw, to: folder, flags: MailProvider.MessageFlags(),
                                             receivedAt: Date().addingTimeInterval(-Double(entry.daysAgo) * 86_400))
                sent.append(raw)
            }
        }
        return sent
    }

    private static func closedPort() async throws -> Int {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
        let port = channel.localAddress!.port!
        try await channel.close()
        return port
    }

    private func storedSubjects() async throws -> Set<String> {
        Set(try await store.summaries(account: account, limit: 1_000).compactMap(\.subject))
    }

    /// Text searches sent to the server (the sync's own are `SEARCH ALL` and `SEARCH SINCE`).
    private var serverSearches: Int {
        captured.lines.filter { $0.contains("→") && $0.contains("UID SEARCH (") }.count
    }

    // MARK: - Tests

    func testOldMailOutsideTheWindowIsFoundOnTheServerOpensAndIsThenFoundLocally() async throws {
        let grace = MailAddress(name: "Grace Hopper", address: "grace@example.com")
        let inbox = try await append([("Invoice March", 90, grace), ("Lunch", 2, nil), ("Invoice April", 60, nil),
                                      ("Invoice today", 0, nil), ("Holiday plans", 45, grace)])
        try await append([("Invoice 2019", 400, nil)], to: "Projects")
        try await sync()
        let stored = try await storedSubjects()
        XCTAssertEqual(stored, ["Lunch", "Invoice today"], "only the last 30 days are downloaded")

        // Local search finds the downloaded invoice only; the server has the older ones.
        let local = try await store.search(SearchQuery(text: "invoice", account: account))
        XCTAssertEqual(local.compactMap(\.subject), ["Invoice today"])
        let search = searcher()
        let found = try await search.search(RemoteSearchCriteria(terms: ["invoice"]))
        XCTAssertEqual(found.total, 3, "the downloaded one is not counted again")
        XCTAssertEqual(found.hits.map(\.subject), ["Invoice April", "Invoice March", "Invoice 2019"], "newest first")
        let march = try XCTUnwrap(found.hits.first { $0.subject == "Invoice March" })
        XCTAssertEqual(march.senderName, "Grace Hopper")
        XCTAssertEqual(march.senderAddress, "grace@example.com")
        XCTAssertEqual(march.folderName, "INBOX")
        XCTAssertEqual(march.location.uid, 1)
        XCTAssertTrue(march.isUnread)
        XCTAssertEqual(found.hits.first { $0.subject == "Invoice 2019" }?.folderName, "Projects")

        // A sender and the words together; a date range narrows by the received date exactly.
        let fromGrace = try await search.search(RemoteSearchCriteria(terms: ["invoice"], participants: ["grace"]))
        XCTAssertEqual(fromGrace.hits.map(\.subject), ["Invoice March"])
        let lastQuarter = try await search.search(RemoteSearchCriteria(
            terms: ["invoice"], receivedOnOrAfter: Date().addingTimeInterval(-75 * 86_400)))
        XCTAssertEqual(lastQuarter.hits.map(\.subject), ["Invoice April"])
        let byName = try await search.search(RemoteSearchCriteria(terms: ["plans"], participants: ["hopper"]))
        XCTAssertEqual(byName.hits.map(\.subject), ["Holiday plans"], "the sender's name counts too")
        let nothing = try await search.search(RemoteSearchCriteria(terms: ["nothing-like-this"]))
        XCTAssertEqual(nothing.total, 0)

        // Opening one stores it like synced mail, byte for byte, where it was found.
        let id = try await search.download(march)
        let original = try await store.originalData(of: id)
        XCTAssertEqual(original, inbox[0])
        let location = try await store.localID(at: march.location, account: account)
        XCTAssertEqual(location, id)
        let again = try await search.download(march)
        XCTAssertEqual(again, id, "opening it again downloads nothing more")
        let count = try await store.messageCount()
        XCTAssertEqual(count, 3)

        // It is now found locally, and no longer on the server.
        let afterLocal = try await store.search(SearchQuery(text: "invoice", account: account))
        XCTAssertEqual(Set(afterLocal.compactMap(\.subject)), ["Invoice today", "Invoice March"])
        let afterServer = try await search.search(RemoteSearchCriteria(terms: ["invoice"]))
        XCTAssertEqual(afterServer.hits.map(\.subject), ["Invoice April", "Invoice 2019"])
        XCTAssertEqual(afterServer.total, 2)

        // The sync knows it: the next pass neither downloads it again nor counts it as left out.
        let coordinator = SyncCoordinator(account: account, connector: imap(), store: store, options: windowed, log: captured.log)
        try await coordinator.syncOnce()
        let afterSync = try await store.messageCount()
        XCTAssertEqual(afterSync, 3)
        let progress = await coordinator.progress
        XCTAssertEqual(progress.olderNotDownloaded, 3)
    }

    func testNoServerSearchWhenNothingIsLeftOut() async throws {
        try await append([("Invoice one", 3, nil), ("Invoice two", 1, nil)])
        try await sync()
        let folders = try await store.syncedFolders(account: account)
        XCTAssertTrue(folders.allSatisfy(\.historyComplete), "everything is within the window: \(folders)")

        let search = searcher()
        let left = try await search.foldersLeftOut()
        XCTAssertEqual(left, [])
        let connectionsBefore = captured.lines.filter { $0.contains("connecting to") }.count
        let found = try await search.search(RemoteSearchCriteria(terms: ["invoice"]))
        XCTAssertEqual(found, ServerSearchResult(hits: [], total: 0))
        XCTAssertEqual(serverSearches, 0, "the server was not asked")
        XCTAssertEqual(captured.lines.filter { $0.contains("connecting to") }.count, connectionsBefore, "nor connected to")
    }

    func testResultsAreCappedToTheNewestAndOnlyTheChosenFolderIsSearched() async throws {
        try await append([("Report 1", 200, nil), ("Report 2", 150, nil), ("Report 3", 100, nil), ("Report 4", 50, nil),
                          ("Today", 0, nil)])
        try await append([("Report archived", 300, nil)], to: "Archive")
        try await sync()
        captured.reset()

        let found = try await searcher(limit: 2).search(RemoteSearchCriteria(terms: ["report"]))
        XCTAssertEqual(found.total, 5)
        XCTAssertEqual(found.hits.map(\.subject), ["Report 4", "Report 3"])
        // Only the newest are summarised: one summary fetch of two UIDs per folder.
        XCTAssertFalse(captured.lines.contains { $0.contains("UID FETCH (4 summaries)") || $0.contains("UID FETCH (3 summaries)") })

        let archive = try await searcher().search(RemoteSearchCriteria(terms: ["report"]), mailbox: "archive")
        XCTAssertEqual(archive.hits.map(\.subject), ["Report archived"], "the folder name matches in any case")
    }

    func testWordsOutsideASCIIAreSearchedAsUTF8() async throws {
        try await append([("Café receipts", 120, nil), ("Today", 0, nil)])
        try await sync()
        let found = try await searcher().search(RemoteSearchCriteria(terms: ["Café"]))
        XCTAssertEqual(found.hits.map(\.subject), ["Café receipts"])
    }

    func testALargeMessageOpensWithoutItsLargeAttachmentLikeTheSyncStoresIt() async throws {
        let attachment = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let sent = try await append([("Scanned contract", 90, nil)], attachment: attachment)
        try await append([("Today", 0, nil)])
        try await sync()

        let search = searcher(onDemandThreshold: 50_000)
        let contract = try await search.search(RemoteSearchCriteria(terms: ["contract"]))
        let hit = try XCTUnwrap(contract.hits.first)
        let id = try await search.download(hit)
        let partial = try await store.isPartial(id)
        XCTAssertTrue(partial, "the attachment stays at the provider until it is opened")
        let text = try await store.search(SearchQuery(text: "contract", account: account))
        XCTAssertEqual(text.map(\.id), [id])

        // Completing it gives the provider's bytes, as for any partial message.
        let fetcher = OnDemandFetcher(account: account, connector: imap(), store: store, log: captured.log)
        try await fetcher.complete([id])
        let original = try await store.originalData(of: id)
        XCTAssertEqual(original, sent[0])
    }

    func testOfflineSaysSoAndAMessageGoneFromTheServerSaysSo() async throws {
        try await append([("Invoice old", 90, nil), ("Today", 0, nil)])
        try await sync()
        let invoices = try await searcher().search(RemoteSearchCriteria(terms: ["invoice"]))
        let hit = try XCTUnwrap(invoices.hits.first)

        // Nothing listens on this port: offline, not a hang or an empty result.
        let closed = try await Self.closedPort()
        do {
            _ = try await searcher(port: closed).search(RemoteSearchCriteria(terms: ["invoice"]))
            XCTFail("an unreachable server must not look like no results")
        } catch let failure as ServerSearcher.Failure {
            guard case .offline = failure else { return XCTFail("\(failure)") }
        }

        // Deleted at the provider after it was found.
        try await imap().withSession { session in
            try await session.expunge([RemoteMessageID(folder: hit.location.mailbox, uidValidity: hit.location.uidValidity,
                                                       uid: hit.location.uid)])
        }
        do {
            _ = try await searcher().download(hit)
            XCTFail("a message gone from the provider cannot be opened")
        } catch let failure as ServerSearcher.Failure {
            XCTAssertEqual(failure, .notAtProvider)
        }
        let count = try await store.messageCount()
        XCTAssertEqual(count, 1)
    }

    func testSearchesTakeTurnsOnOneConnectionAndACancelledOneStops() async throws {
        try await append([("Invoice a", 90, nil), ("Invoice b", 80, nil), ("Today", 0, nil)])
        try await append([("Invoice c", 70, nil)], to: "Projects")
        try await append([("Invoice d", 60, nil)], to: "Archive")
        try await sync()
        let search = searcher()
        captured.reset()

        // A stale search, cancelled at once, and three more at the same time.
        let stale = Task { try await search.search(RemoteSearchCriteria(terms: ["invoice"])) }
        stale.cancel()
        async let first = search.search(RemoteSearchCriteria(terms: ["invoice"]))
        async let second = search.search(RemoteSearchCriteria(terms: ["invoice"], participants: ["ada"]))
        async let third = search.search(RemoteSearchCriteria(terms: ["today"]))
        let results = try await [first, second, third]
        XCTAssertEqual(results.map(\.total), [4, 4, 0])
        _ = await stale.result

        // Never two connections of the searcher at once: each logs out before the next connects.
        var open = 0
        var most = 0
        for line in captured.lines {
            if line.contains("connecting to") { open += 1; most = max(most, open) }
            if line.contains("LOGOUT") && line.contains("→") { open -= 1 }
        }
        XCTAssertEqual(most, 1, captured.lines.filter { $0.contains("connecting") || $0.contains("LOGOUT") }.joined(separator: "\n"))
    }
}
