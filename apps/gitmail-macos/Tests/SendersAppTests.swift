import XCTest
import MailAccounts
import MailClassifier
import MailCore
import MailProvider
import MailStore
import MailSync
import MailUnsubscribe

/// GKM-019 and GKM-020 through the app model, against a real store in a temporary folder and a
/// real local HTTP server that records every request: the Senders view, a rule's preview and
/// what applying it then does (receipts kept while a shop's offers are muted), Undo, silence for
/// notifications, archiving at the provider only when a rule asks (through the action journal),
/// and unsubscribe that contacts nothing until you approve and never a suspicious sender.
@MainActor
final class SendersAppTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var credentials: KeychainCredentialStore!
    private var server: RecordingHTTPServer!
    private let home = MailAccountID("home")
    private let me = "sam.rivera@example.net"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gitmail-senders-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
        defaultsSuite = "gitmail-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        credentials = KeychainCredentialStore(service: "app.hakobs.gitmail.tests.\(UUID().uuidString)", useDataProtectionKeychain: false)
        server = try await RecordingHTTPServer.start()
    }

    override func tearDown() async throws {
        server.stop()
        defaults?.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }

    private func services() -> AccountServices {
        let connections = AccountConnections(trust: .system, connectTimeout: .seconds(5), commandTimeout: .seconds(15))
        return AccountServices(
            credentials: credentials, connections: connections, verifier: AccountVerifier(connections: connections),
            syncOptions: SyncOptions(idleTimeout: .seconds(30),
                                     reconnect: ReconnectPolicy(initialDelay: .milliseconds(50), maxDelay: .milliseconds(200), jitter: 0)),
            defaults: defaults)
    }

    private static func eml(from: String, subject: String, day: Int, headers: [String] = [], body: String = "Hello") -> Data {
        let weekday = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][(day - 1) % 7]
        let lines = ["From: \(from)", "To: sam.rivera@example.net", "Subject: \(subject)",
                     String(format: "Date: %@, %02d Nov 2026 10:00:00 +0000", weekday, day), "Message-ID: <\(UUID().uuidString)@example.net>"]
            + headers + ["MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8", "", body, ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private var offerHeaders: [String] {
        ["List-ID: Shop offers <offers.shop.example>",
         "List-Unsubscribe: <\(server.url("/u/offers").absoluteString)>, <mailto:leave@shop.example?subject=unsubscribe>",
         "List-Unsubscribe-Post: List-Unsubscribe=One-Click", "Precedence: bulk"]
    }

    /// A shop's receipts (sent directly) and offers (through its list), in the inbox of an
    /// account whose folders the sync knows.
    @discardableResult
    private func seedShop() async throws -> (receipts: [MailMessageID], offers: [MailMessageID]) {
        let store = try await MailStore.open(locations)
        try await store.save(MailAccount(id: home, displayName: "Home", address: me))
        try await store.replaceSyncedFolders([SyncedFolder(name: "INBOX", path: ["INBOX"], role: "inbox"),
                                              SyncedFolder(name: "Archive", path: ["Archive"], role: "archive"),
                                              SyncedFolder(name: "Junk", path: ["Junk"], role: "junk")], account: home)
        var receipts: [MailMessageID] = [], offers: [MailMessageID] = []
        var uid: UInt32 = 0
        for day in 1...3 {
            uid += 1
            receipts.append(try await store.ingest(Self.eml(from: "Shop <orders@shop.example>", subject: "Your receipt for order #10\(day)", day: day,
                                                            body: "Order #10\(day). Total paid: €24.95"), account: home,
                                                   remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: uid)).id)
            uid += 1
            offers.append(try await store.ingest(Self.eml(from: "Shop <news@shop.example>", subject: "50% off sale this weekend", day: day + 3,
                                                          headers: offerHeaders, body: "Shop now, limited time offer."), account: home,
                                                 remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: uid)).id)
        }
        return (receipts, offers)
    }

    private func openModel() async -> AppModel {
        let model = AppModel(locations: locations, services: services())
        model.senders.unsubscribe.policy = EndpointPolicy(loopbackHTTPPorts: [Int(server.port)])
        await model.open()
        await model.attention.waitForClassification()
        await model.senders.refresh()
        return model
    }

    private func ids(_ model: AppModel, _ category: MailCategory) async throws -> Set<MailMessageID> {
        Set(try await model.mailStore!.search(SearchQuery(account: home, category: category), limit: 500).map(\.id))
    }

    private func list(_ model: AppModel) throws -> SenderSummary {
        try XCTUnwrap(model.senders.senders.first { $0.scope.listID == "offers.shop.example" })
    }

    // MARK: GKM-019

    func testTheSendersViewListsTheShopsListAndSender() async throws {
        try await seedShop()
        let model = await openModel()
        await model.select(.senders)
        XCTAssertEqual(model.selection, .senders)
        let list = try list(model)
        XCTAssertEqual(list.messages, 3)
        XCTAssertEqual(list.mainCategory, .promotions)
        XCTAssertTrue(model.senders.senders.contains { $0.scope == .sender("orders@shop.example") })
        model.senders.filter = "orders@"
        XCTAssertEqual(model.senders.visible.map(\.scope), [.sender("orders@shop.example")])
        model.senders.filter = ""
        model.senders.sort = .name
        XCTAssertEqual(model.senders.visible.count, 2)
    }

    func testMutingTheShopsOffersPreviewsThenAppliesExactlyThatAndKeepsReceipts() async throws {
        let (receipts, offers) = try await seedShop()
        let model = await openModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.senders.undoManager = undo
        let focusedBefore = try await ids(model, .focused)

        await model.senders.propose(.mute, for: try list(model))
        let pending = try XCTUnwrap(model.senders.pending)
        XCTAssertEqual(Set(pending.preview.changed.map(\.id)), Set(offers), "the preview names every offer and nothing else")
        let value1 = try await ids(model, .promotions)
        XCTAssertEqual(value1, Set(offers), "nothing changed before Apply")

        let resultValue = await model.senders.apply()
        let result = try XCTUnwrap(resultValue)
        XCTAssertNil(model.senders.pending)
        XCTAssertEqual(result.items.map(\.id), pending.preview.items.map(\.id))
        for (planned, applied) in zip(pending.preview.items, result.items) { XCTAssertEqual(planned.after, applied.after) }

        let value2 = try await ids(model, .promotions).isDisjoint(with: offers)
        XCTAssertTrue(value2)
        let value3 = try await ids(model, .transactions)
        XCTAssertEqual(value3, Set(receipts), "receipts from the same shop stay")
        let value4 = try await ids(model, .focused)
        XCTAssertEqual(value4, focusedBefore)
        XCTAssertEqual(model.attention.count(.promotions).total, 0, "the sidebar counts follow")
        let store = try XCTUnwrap(model.mailStore)
        let queued = try await store.actionStatus(account: home).pending
        XCTAssertEqual(queued, 0, "muting is virtual: nothing queued for the provider")

        XCTAssertEqual(undo.undoActionName, "Mute Shop")
        undo.undo()
        await model.senders.waitForUndo()
        let value5 = try await ids(model, .promotions)
        XCTAssertEqual(value5, Set(offers), "Undo brings the offers back")
        XCTAssertTrue(model.senders.rules.isEmpty)
    }

    func testMutedMailNeverNotifiesAndTheReaderSaysWhichRuleWon() async throws {
        let (_, offers) = try await seedShop()
        let model = await openModel()
        await model.senders.propose(.inbox, for: try list(model))
        await model.senders.apply()
        await model.senders.propose(.mute, for: try list(model))
        await model.senders.apply()
        XCTAssertEqual(model.senders.rules.count, 1, "a new rule for the same list replaces the old one")

        let store = try XCTUnwrap(model.mailStore)
        let arrival = try await store.arrivals(after: 0).first { $0.id == offers[2] }
        var settings = NotificationSettings()
        settings.lists[NotificationSettings.ListKey(account: home, list: "offers.shop.example")] = .always
        XCTAssertEqual(arrival?.isSilenced, true)
        XCTAssertFalse(settings.notifies(try XCTUnwrap(arrival)), "a muted list never notifies, even set to Always")

        let explanation = await model.senderRuleExplanation(for: offers[0])
        XCTAssertEqual(explanation?.winner.action, .mute)
        XCTAssertEqual(explanation?.position, 1)
        let verdict = try await store.verdict(of: offers[0])
        XCTAssertEqual(VerdictText.summary(try XCTUnwrap(verdict)), "Muted by your rule for this sender. Still in All Mail.")
    }

    func testARuleArchivesAtTheProviderOnlyWhenAskedAndThroughTheJournal() async throws {
        let (receipts, offers) = try await seedShop()
        let model = await openModel()
        let store = try XCTUnwrap(model.mailStore)
        await model.senders.propose(.keepLatestOnly, for: try list(model))
        await model.senders.apply()
        await model.senders.lastProviderArchive?.value
        var queued = try await store.actionStatus(account: home).pending
        XCTAssertEqual(queued, 0, "without asking, nothing moves at the provider")

        let rule = try XCTUnwrap(model.senders.rules.first)
        await model.senders.proposeArchiveAtProvider(true, rule: rule)
        await model.senders.apply()
        await model.senders.lastProviderArchive?.value
        queued = try await store.actionStatus(account: home).pending
        XCTAssertEqual(queued, 2, "the two older offers are archived through the journal; the newest stays")
        for offer in offers.prefix(2) {
            let boxes = try await store.effectiveMailboxes(of: offer)
            XCTAssertEqual(boxes, ["Archive"])
        }
        let newest = try await store.effectiveMailboxes(of: offers[2])
        XCTAssertEqual(newest, ["INBOX"])
        for receipt in receipts {
            let boxes = try await store.effectiveMailboxes(of: receipt)
            XCTAssertEqual(boxes, ["INBOX"], "receipts are never touched")
        }
    }

    // MARK: GKM-020

    func testUnsubscribeContactsNothingUntilApprovedThenSendsOnePOST() async throws {
        try await seedShop()
        let model = await openModel()
        await model.select(.senders)
        let list = try list(model)
        model.senders.selectedID = list.id
        let option = await model.senders.unsubscribe.option(for: list)
        XCTAssertEqual(option.assessment.method, .oneClick(server.url("/u/offers")))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(server.connections, 0, "opening, sorting, listing and assessing contacted nothing")

        // A URL that isn't the one offered is never sent.
        let other = await model.senders.unsubscribe.approveOneClick(server.url("/u/other"), for: list)
        XCTAssertNil(other)
        XCTAssertEqual(server.connections, 0)

        server.responses["/u/offers"] = .init(status: 202)
        let requestValue = await model.senders.unsubscribe.approveOneClick(server.url("/u/offers"), for: list)
        let request = try XCTUnwrap(requestValue)
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(server.requests.first?.method, "POST")
        XCTAssertEqual(server.requests.first?.body, "List-Unsubscribe=One-Click")
        XCTAssertNil(server.requests.first?.header("Cookie"))
        XCTAssertEqual(request.state, .pending, "accepted is pending, not unsubscribed")
        XCTAssertEqual(model.senders.unsubscribe.request(for: list)?.state, .pending)

        // Mail still arrives after the grace period: the request failed.
        let store = try XCTUnwrap(model.mailStore)
        var saved = try XCTUnwrap(model.senders.unsubscribe.request(for: list))
        saved.requestedAt = Date(timeIntervalSince1970: 1_793_000_000) // before the offers were sent
        try await store.saveUnsubscribeRequest(saved)
        await model.senders.unsubscribe.refresh()
        XCTAssertEqual(model.senders.unsubscribe.request(for: list)?.state, .failed)
    }

    func testSuspectedSpamIsNeverOfferedUnsubscribeAndIsReportedAsJunkInstead() async throws {
        let store = try await MailStore.open(locations)
        try await store.save(MailAccount(id: home, displayName: "Home", address: me))
        try await store.replaceSyncedFolders([SyncedFolder(name: "INBOX", path: ["INBOX"], role: "inbox"),
                                              SyncedFolder(name: "Junk", path: ["Junk"], role: "junk")], account: home)
        let spam = try await store.ingest(Self.eml(from: "Winner <prize@lucky-draw.example>", subject: "You are a winner! Claim your prize now",
                                                   day: 2, headers: ["List-ID: <prizes.lucky-draw.example>",
                                                                     "List-Unsubscribe: <\(server.url("/u/spam").absoluteString)>",
                                                                     "List-Unsubscribe-Post: List-Unsubscribe=One-Click"],
                                                   body: "Congratulations, you have won a lottery prize. Act now, wire transfer the claim fee."),
                                          account: home, remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 1)).id
        let model = await openModel()
        let opened = try XCTUnwrap(model.mailStore)
        let verdict = try await opened.verdict(of: spam)
        XCTAssertEqual(verdict?.classification.risk, .spam, "fixture: the classifier calls it spam")
        let sender = try XCTUnwrap(model.senders.senders.first { $0.scope.listID == "prizes.lucky-draw.example" })
        let option = await model.senders.unsubscribe.option(for: sender)
        XCTAssertEqual(option.assessment.outcome, .refused(.risky(.spam)))
        XCTAssertTrue(option.assessment.suggestsReportingJunk)
        let attempt = await model.senders.unsubscribe.approveOneClick(server.url("/u/spam"), for: sender)
        XCTAssertNil(attempt, "even asked directly, nothing is sent")
        XCTAssertEqual(server.connections, 0)

        await model.reportJunk(spam)
        let boxes = try await opened.effectiveMailboxes(of: spam)
        XCTAssertEqual(boxes, ["Junk"], "reported: moved to the provider's junk folder through the journal")
        let value6 = try await opened.correction(of: spam)?.risk
        XCTAssertEqual(value6, .spam)
    }

    func testAMailtoUnsubscribeIsPreviewedFromYourAddressAndQueuedInTheOutbox() async throws {
        try await seedShop()
        let model = await openModel()
        let list = try list(model)
        let option = await model.senders.unsubscribe.option(for: list)
        guard case .offer(_, let alternatives) = option.assessment.outcome,
              case .mailto(let address, let subject, let body)? = alternatives.first else { return XCTFail("\(option.assessment)") }
        let draft = model.senders.unsubscribe.mailtoDraft(address: address, subject: subject, body: body, for: list, source: option.source)
        XCTAssertEqual(draft.from?.address, me, "sent from the address the list writes to")
        XCTAssertEqual(draft.to.map(\.address), ["leave@shop.example"])
        XCTAssertEqual(draft.subject, "unsubscribe")

        await model.senders.unsubscribe.sendMailto(draft, for: list)
        let request = try XCTUnwrap(model.senders.unsubscribe.request(for: list))
        XCTAssertEqual(request.method, "mailto")
        XCTAssertEqual(request.state, .requested, "queued is not sent, and sent is not unsubscribed")
        let operation = try XCTUnwrap(request.outboxOperation)
        for _ in 0..<100 where model.sending?.outbox.contains(where: { $0.id.rawValue == operation }) != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        let entry = try XCTUnwrap(model.sending?.outbox.first { $0.id.rawValue == operation })
        XCTAssertEqual(entry.account, home)
        XCTAssertEqual(server.connections, 0, "a mailto unsubscribe contacts no web endpoint")
    }

}
