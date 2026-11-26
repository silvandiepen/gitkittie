import Darwin
import Synchronization
import XCTest
import MailAccounts
import MailClassifier
import MailCore
import MailProvider
import MailStore
import MailSync

/// Searching the provider for mail the history window left there, through the app model
/// (GKM-041, MAIL-081..083): the real store in a temporary folder, the real Keychain (a test-only
/// service) and the local test mail server. Without the server these tests skip.
@MainActor
final class ServerSearchAppTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var credentials: KeychainCredentialStore!
    private let lines = LockedLines()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm041-app-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
        defaultsSuite = "gitmail-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        credentials = KeychainCredentialStore(service: "app.hakobs.gitmail.tests.\(UUID().uuidString)", useDataProtectionKeychain: false)
    }

    override func tearDown() async throws {
        if let locations, let store = try? await MailStore.open(locations) {
            for account in (try? await store.accounts()) ?? [] { try? credentials.delete(for: account.id) }
        }
        defaults?.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    /// The iPhone's history window (30 days), and every IMAP command in `lines`.
    private func services(trust: TrustPolicy, historyDays: Int? = 30) -> AccountServices {
        let log = MailLog(minimumLevel: .trace) { [lines] record in lines.append("\(record.category): \(record.message)") }
        let connections = AccountConnections(trust: trust, log: log, connectTimeout: .seconds(5), commandTimeout: .seconds(15))
        return AccountServices(
            credentials: credentials, connections: connections, verifier: AccountVerifier(connections: connections),
            syncOptions: SyncOptions(historyDays: historyDays, idleTimeout: .seconds(30),
                                     reconnect: ReconnectPolicy(initialDelay: .milliseconds(50), maxDelay: .milliseconds(200), jitter: 0)),
            defaults: defaults)
    }

    private func draft(_ server: LocalMailServer, _ user: LocalMailServer.User) -> AccountDraft {
        var draft = AccountDraft()
        draft.provider = .other
        draft.address = user.address
        draft.password = user.password
        draft.imapHost = "localhost"
        draft.imapPort = server.imapsPort
        draft.smtpHost = "localhost"
        draft.smtpPort = server.smtpsPort
        draft.smtpSecurity = .implicitTLS
        draft.name = "Test"
        return draft
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(20), _ condition: () async throws -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now + timeout
        while clock.now < end {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// A model with the account added and its first sync done.
    private func syncedModel(_ subjects: [String], receivedDaysAgo: [Int], historyDays: Int? = 30)
        async throws -> (AppModel, MailAccount, LocalMailServer) {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        try await server.append(subjects, for: user, receivedDaysAgo: receivedDaysAgo)
        let model = AppModel(locations: locations, services: services(trust: server.trust, historyDays: historyDays))
        model.browser.serverSearchDelay = .zero
        await model.open()
        let account = try await model.addAccount(draft(server, user))
        try await waitUntil("the first sync") { model.syncStatus(account.id)?.hasPrefix("Up to date") == true }
        return (model, account, server)
    }

    private var textSearches: Int { lines.all.filter { $0.contains("→") && $0.contains("UID SEARCH (") }.count }

    private func subjects(_ model: AppModel) -> [String] { model.browser.rows.compactMap(\.latest.subject) }

    /// A local port nothing listens on.
    private static func closedPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound else { throw POSIXError(.EADDRINUSE) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    // MARK: - Tests

    func testTheServerHalfOfASearchIsItsWordsPeopleAndDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parsed = SearchQuery.parse("from:grace \"march invoice\" tax-2019 is:unread after:2026-01-02 in:Archive", calendar: calendar)
        let query = ServerQuery.make(parsed, explicitCategory: nil)
        XCTAssertEqual(query?.criteria.terms, ["march invoice", "tax", "2019"], "a phrase stays whole; words split as local search splits them")
        XCTAssertEqual(query?.criteria.participants, ["grace"])
        XCTAssertEqual(query?.criteria.receivedOnOrAfter, calendar.date(from: DateComponents(year: 2026, month: 1, day: 2)))
        XCTAssertEqual(query?.criteria.unreadOnly, true)
        XCTAssertEqual(query?.mailbox, "Archive")
        XCTAssertNil(query?.unavailable)

        XCTAssertNil(ServerQuery.make(SearchQuery.parse("is:unread has:attachment"), explicitCategory: nil),
                     "without words or people the server is not asked")
        XCTAssertNotNil(ServerQuery.make(SearchQuery(text: "invoice", category: .focused), explicitCategory: nil)?.criteria,
                        "the category view searched in does not stop it")
        XCTAssertNotNil(ServerQuery.make(SearchQuery(text: "invoice"), explicitCategory: .transactions)?.unavailable)
        XCTAssertNotNil(ServerQuery.make(SearchQuery(text: "invoice", space: MailSpaceID()), explicitCategory: nil)?.unavailable)
    }

    /// "See All Mail from…" (GKM-071, MAIL-098): the sender's older mail is asked of the server
    /// by FROM, and only that exact address is shown, though IMAP matches a longer one too.
    func testSeeAllMailFromAlsoFindsTheSendersOlderMailOnTheServer() async throws {
        XCTAssertEqual(ServerQuery.make(SearchQuery(sender: "deals@shop.example"), explicitCategory: nil)?.criteria.senders,
                       ["deals@shop.example"], "a sender alone is enough to ask")
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        try await server.append(["Deal old", "Deal new"], for: user, receivedDaysAgo: [90, 0], from: "Deals <deals@shop.example>")
        try await server.append(["Hot old"], for: user, receivedDaysAgo: [90], from: "Hot <hot-deals@shop.example>")
        try await server.append(["Bo old"], for: user, receivedDaysAgo: [90])
        let model = AppModel(locations: locations, services: services(trust: server.trust))
        model.browser.serverSearchDelay = .zero
        await model.open()
        let account = try await model.addAccount(draft(server, user))
        try await waitUntil("the first sync") { model.syncStatus(account.id)?.hasPrefix("Up to date") == true }

        await model.showAllMail(from: MailAddress(name: "Deals", address: "deals@shop.example"))
        XCTAssertEqual(subjects(model), ["Deal new"])
        try await waitUntil("the server's results") { !model.browser.server.hits.isEmpty }
        XCTAssertEqual(model.browser.server.hits.map(\.subject), ["Deal old"], "never hot-deals@, never Bo")
        XCTAssertEqual(model.browser.server, .found(model.browser.server.hits, total: 1))
        await model.sync.stopAll()
    }

    func testOldMailIsFoundOnTheServerOpensAndIsThenALocalResult() async throws {
        let (model, account, _) = try await syncedModel(["Invoice March", "Lunch", "Invoice April", "Invoice today"],
                                                        receivedDaysAgo: [90, 1, 60, 0])
        let browser = model.browser
        XCTAssertEqual(model.syncStatus(account.id), "Up to date · older than 30 days not downloaded")
        await model.select(.allMail)

        await browser.search("invoice")
        XCTAssertEqual(subjects(model), ["Invoice today"], "only downloaded mail is a local result")
        try await waitUntil("the server's results") { !browser.server.hits.isEmpty }
        XCTAssertEqual(browser.server.hits.map(\.subject), ["Invoice April", "Invoice March"])
        XCTAssertEqual(browser.server, .found(browser.server.hits, total: 2))
        XCTAssertNil(browser.server.note, "two results need no note")
        XCTAssertEqual(browser.server.hits.first?.whereLine, "INBOX · not downloaded")
        let searches = textSearches
        XCTAssertEqual(searches, 1)

        // The sync storing mail reloads the list; an unchanged search is not sent again.
        await browser.reload()
        XCTAssertEqual(textSearches, searches)

        // Opening one downloads it, shows it, and it is a local result from then on.
        let march = try XCTUnwrap(browser.server.hits.first { $0.subject == "Invoice March" })
        await browser.openServerHit(march)
        XCTAssertNil(browser.actionError)
        XCTAssertEqual(Set(subjects(model)), ["Invoice today", "Invoice March"])
        let opened = try XCTUnwrap(browser.openThread?.messages.first { $0.isExpanded })
        XCTAssertEqual(opened.summary.subject, "Invoice March")
        XCTAssertEqual(browser.selectedRowID, ListRow.id(of: opened.id))
        XCTAssertNotNil(opened.content, "the reader shows it")
        XCTAssertEqual(browser.server.hits.map(\.subject), ["Invoice April"])

        // A new search finds it locally and the server only has the other one now.
        await browser.search("")
        XCTAssertEqual(browser.server, .off)
        await browser.search("invoice")
        XCTAssertEqual(Set(subjects(model)), ["Invoice today", "Invoice March"])
        try await waitUntil("the server's results") { browser.server.hits.map(\.subject) == ["Invoice April"] }

        // In a category view the server is searched too: mail there has no category yet.
        await browser.search("")
        await model.select(.category(.focused))
        await browser.search("april")
        try await waitUntil("the server's results in Focused") { browser.server.hits.map(\.subject) == ["Invoice April"] }

        // Filters only this device knows say why the server is not asked.
        await browser.setFilters(SearchFilters(hasAttachment: true))
        XCTAssertEqual(browser.server, .unavailable("Mail on the server can’t be searched for attachments."))
        await model.sync.stopAll()
    }

    func testNoServerSearchWhenNothingIsLeftOut() async throws {
        let (model, account, _) = try await syncedModel(["Invoice one", "Invoice two"], receivedDaysAgo: [3, 1])
        let browser = model.browser
        XCTAssertEqual(model.syncStatus(account.id), "Up to date")
        await model.select(.allMail)
        await browser.search("invoice")
        XCTAssertEqual(Set(subjects(model)), ["Invoice one", "Invoice two"])
        XCTAssertEqual(browser.server, .off)
        XCTAssertFalse(model.sync.leavesMailOnServer(account: nil))
        XCTAssertEqual(textSearches, 0, "the server was not asked")
        await model.sync.stopAll()
    }

    func testWithoutAHistoryLimitTheMacNeverSearchesTheServer() async throws {
        // The Mac's default: no window and no budget, so everything comes down.
        let (model, _, _) = try await syncedModel(["Invoice old", "Invoice new"], receivedDaysAgo: [400, 0], historyDays: nil)
        await model.select(.allMail)
        await model.browser.search("invoice")
        XCTAssertEqual(Set(subjects(model)), ["Invoice old", "Invoice new"])
        XCTAssertEqual(model.browser.server, .off)
        XCTAssertEqual(textSearches, 0)
        await model.sync.stopAll()
    }

    func testOfflineSaysSoAndSearchesOnceConnectedAgain() async throws {
        let (model, account, _) = try await syncedModel(["Invoice March", "Lunch"], receivedDaysAgo: [90, 0])
        let browser = model.browser
        await model.select(.allMail)
        let store = try XCTUnwrap(model.mailStore)

        // The connection goes: the account's server stops answering.
        await model.sync.stop(account.id)
        var unreachable = account
        unreachable.connection?.imap.port = try Self.closedPort()
        await model.sync.start(unreachable, store: store)
        try await waitUntil("offline") { model.syncStatus(account.id)?.hasPrefix("Offline") == true }
        await browser.search("invoice")
        XCTAssertEqual(browser.server, .offline)
        XCTAssertEqual(browser.server.note, "You’re offline. Older mail on the server is searched when you’re connected again.")
        XCTAssertEqual(textSearches, 0)

        // Back online: the sync's next pass reloads the list, and the search goes out.
        await model.sync.stop(account.id)
        await model.sync.start(account, store: store)
        try await waitUntil("the server's results once connected") { browser.server.hits.map(\.subject) == ["Invoice March"] }
        await model.sync.stopAll()
    }
}

/// Log lines from the connections, collected from any thread.
private final class LockedLines: Sendable {
    private let lines = Mutex<[String]>([])

    func append(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
}
