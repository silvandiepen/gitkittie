import XCTest
import MailClassifier
import MailCore
@testable import MailStore

/// GKM-019 in the store: the sender and list directory, and sender rules — the preview is what
/// applying then does, receipts survive muting a shop's offers, rule order and the reason a
/// rule won, exclusions, disabling, Undo, keep-latest, and rules never touching risky or
/// security mail. All synthetic addresses on reserved example domains.
final class SenderRulesTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let account = MailAccountID("home")
    private let me = "sam.rivera@example.net"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("senders-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func open() async throws -> MailStore {
        let store = try await MailStore.open(locations)
        try await store.save(MailAccount(id: account, displayName: "Home", address: me))
        return store
    }

    static func eml(from: String, subject: String, day: Int, id: String = UUID().uuidString, headers: [String] = [],
                    body: String = "Hello", to: String = "sam.rivera@example.net") -> Data {
        let date = String(format: "%@, %02d Nov 2026 10:00:00 +0000", ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][(day - 1) % 7], day)
        let lines = ["From: \(from)", "To: \(to)", "Subject: \(subject)", "Date: \(date)", "Message-ID: <\(id)@example.net>"]
            + headers + ["MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8", "", body, ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    static let offerHeaders = [
        "List-ID: Shop offers <offers.shop.example>",
        "List-Unsubscribe: <https://unsubscribe.shop.example/u/abc>, <mailto:leave@shop.example?subject=unsubscribe>",
        "List-Unsubscribe-Post: List-Unsubscribe=One-Click",
        "Precedence: bulk",
    ]

    /// A shop that sends receipts directly and offers through its list.
    private func seedShop(_ store: MailStore) async throws -> (receipts: [MailMessageID], offers: [MailMessageID]) {
        var receipts: [MailMessageID] = [], offers: [MailMessageID] = []
        for day in 1...3 {
            receipts.append(try await store.ingest(Self.eml(from: "Shop <orders@shop.example>", subject: "Your receipt for order #10\(day)",
                                                            day: day, body: "Order #10\(day). Total paid: €24.95"), account: account).id)
            offers.append(try await store.ingest(Self.eml(from: "Shop <news@shop.example>", subject: "50% off sale this weekend",
                                                          day: day + 3, headers: Self.offerHeaders, body: "Shop now, limited time offer."),
                                                 account: account).id)
        }
        return (receipts, offers)
    }

    private func ids(_ store: MailStore, _ category: MailCategory) async throws -> Set<MailMessageID> {
        Set(try await store.search(SearchQuery(account: account, category: category), limit: 500).map(\.id))
    }

    private static let offerList = SenderScope.list(id: "offers.shop.example", organisation: "shop.example")

    // MARK: Directory

    func testTheDirectoryListsListsAndSendersWithVolumeCategoriesAndOpens() async throws {
        let store = try await open()
        let (receipts, _) = try await seedShop(store)
        let senders = try await store.senders(account: account, now: Date(timeIntervalSince1970: 1_793_000_000))
        let list = try XCTUnwrap(senders.first { $0.scope == Self.offerList })
        XCTAssertEqual(list.messages, 3)
        XCTAssertEqual(list.unread, 3)
        XCTAssertEqual(list.organisation, "shop.example")
        XCTAssertEqual(list.mainCategory, .promotions)
        XCTAssertEqual(list.name, "Shop")
        let orders = try XCTUnwrap(senders.first { $0.scope == .sender("orders@shop.example") })
        XCTAssertEqual(orders.messages, 3)
        XCTAssertEqual(orders.categories[.transactions], 3)
        XCTAssertEqual(orders.opens, 0)

        try await store.recordOpen(of: receipts[0])
        try await store.recordOpen(of: receipts[1])
        let reopened = try await MailStore.open(locations)
        let after = try await reopened.senders(account: account).first { $0.scope == .sender("orders@shop.example") }
        XCTAssertEqual(after?.opens, 2, "opens in this app are kept on this Mac")
        XCTAssertNotNil(after?.lastOpened)
    }

    // MARK: Receipts and offers

    func testMutingAShopsOffersKeepsItsReceipts() async throws {
        let store = try await open()
        let (receipts, offers) = try await seedShop(store)
        let value1 = try await ids(store, .promotions)
        XCTAssertEqual(value1, Set(offers))

        let rule = SenderRule(account: account, scope: Self.offerList, action: .mute)
        try await store.setSenderRules([rule])

        let value2 = try await ids(store, .promotions).isDisjoint(with: offers)
        XCTAssertTrue(value2, "muted offers leave Promotions")
        let value3 = try await ids(store, .focused).isDisjoint(with: offers)
        XCTAssertTrue(value3)
        let value4 = try await ids(store, .transactions)
        XCTAssertEqual(value4, Set(receipts), "every receipt stays in Transactions")
        let all = Set(try await store.search(SearchQuery(account: account), limit: 500).map(\.id))
        XCTAssertTrue(all.isSuperset(of: offers), "muted mail is still in All Mail")
        for offer in offers {
            let verdict = try await store.verdict(of: offer)
            XCTAssertEqual(verdict?.disposition, .muted)
            XCTAssertEqual(verdict?.senderRule, rule.id)
        }
        let counts = try await store.categoryCounts(account: account)
        XCTAssertEqual(counts[.promotions]?.total ?? 0, 0, "counts agree with the views")
        XCTAssertEqual(counts[.transactions]?.total, 3)
    }

    func testKeepTransactionsOnlyForOneSenderMutesItsOffersAndKeepsItsReceipts() async throws {
        let store = try await open()
        var receipts: [MailMessageID] = [], offers: [MailMessageID] = []
        for day in 1...2 {
            receipts.append(try await store.ingest(Self.eml(from: "hello@store.example", subject: "Your receipt for order #20\(day)", day: day,
                                                            headers: ["Auto-Submitted: auto-generated"],
                                                            body: "Order #20\(day). Total: $12.00"), account: account).id)
            offers.append(try await store.ingest(Self.eml(from: "hello@store.example", subject: "Flash sale: 30% off everything", day: day + 2,
                                                          headers: ["List-Unsubscribe: <mailto:leave@store.example>", "Precedence: bulk"]),
                                                 account: account).id)
        }
        let security = try await store.ingest(Self.eml(from: "hello@store.example", subject: "Your verification code is 482913", day: 6,
                                                       headers: ["Auto-Submitted: auto-generated"], body: "Use 482913 to sign in."),
                                              account: account).id
        let value5 = try await store.verdict(of: security)?.classification.purpose
        XCTAssertEqual(value5, .security)
        let rule = SenderRule(account: account, scope: .sender("hello@store.example"), action: .keepTransactionsOnly)
        let preview = try await store.previewSenderRules([rule])
        XCTAssertEqual(Set(preview.changed.map(\.id)), Set(offers), "only the offers change")
        XCTAssertEqual(Set(preview.items.filter { $0.protection == .transaction }.map(\.id)), Set(receipts))
        XCTAssertEqual(preview.items.first { $0.id == security }?.protection, .security, "account security mail is never hidden")

        try await store.setSenderRules([rule])
        let value6 = try await ids(store, .transactions)
        XCTAssertEqual(value6, Set(receipts))
        let value7 = try await ids(store, .promotions).isDisjoint(with: offers)
        XCTAssertTrue(value7)
        let value8 = try await ids(store, .focused).contains(security)
        XCTAssertTrue(value8)
    }

    // MARK: Preview and apply

    func testThePreviewIsExactlyWhatApplyingDoesAndChangesNothingItself() async throws {
        let store = try await open()
        let (receipts, offers) = try await seedShop(store)
        let before = try await placements(store, receipts + offers)
        let rules = [
            SenderRule(account: account, scope: Self.offerList, action: .keepLatestOnly),
            SenderRule(account: account, scope: .sender("orders@shop.example"), action: .silentArchive),
        ]
        let preview = try await store.previewSenderRules(rules)
        let value9 = try await placements(store, receipts + offers)
        XCTAssertEqual(value9, before, "a preview (dry run) writes nothing")
        let value10 = try await store.senderRules()
        XCTAssertEqual(value10, [])
        XCTAssertEqual(Set(preview.items.map(\.id)), Set(receipts + offers))

        let (previous, result) = try await store.setSenderRules(rules)
        XCTAssertEqual(previous, [])
        XCTAssertEqual(result.items.map(\.id), preview.items.map(\.id))
        for (planned, applied) in zip(preview.items, result.items) {
            XCTAssertEqual(planned.after, applied.after, "message \(planned.id): preview and result differ")
        }
        XCTAssertEqual(result.changed.count, 5, "two older offers muted, three receipts archived; the newest offer stays")
        let saved = try await placements(store, receipts + offers)
        for item in result.items { XCTAssertEqual(saved[item.id], item.after) }
    }

    func testRuleOrderDecidesAndTheExplanationSaysWhyAndWhatElseMatched() async throws {
        let store = try await open()
        let (_, offers) = try await seedShop(store)
        let mute = SenderRule(account: account, scope: Self.offerList, action: .mute)
        let inbox = SenderRule(account: account, scope: .sender("news@shop.example"), action: .inbox)
        try await store.setSenderRules([mute, inbox])
        let value11 = try await store.verdict(of: offers[0])?.disposition
        XCTAssertEqual(value11, .muted)
        var explanation = try await store.explainSenderRule(for: offers[0])
        XCTAssertEqual(explanation?.winner.id, mute.id)
        XCTAssertEqual(explanation?.position, 1)
        XCTAssertEqual(explanation?.alsoMatched.map(\.id), [inbox.id])

        try await store.setSenderRules([inbox, mute])
        let value12 = try await store.verdict(of: offers[0])?.disposition
        XCTAssertEqual(value12, .inbox)
        let value13 = try await ids(store, .focused).isSuperset(of: offers)
        XCTAssertTrue(value13, "the inbox rule now wins")
        explanation = try await store.explainSenderRule(for: offers[0])
        XCTAssertEqual(explanation?.winner.id, inbox.id)
        XCTAssertEqual(explanation?.effect, .disposition(.inbox))
    }

    func testDisablingAndUndoingARuleRestoresWhatWasThere() async throws {
        let store = try await open()
        let (receipts, offers) = try await seedShop(store)
        let original = try await placements(store, receipts + offers)
        var rule = SenderRule(account: account, scope: Self.offerList, action: .mute)
        let (previous, _) = try await store.setSenderRules([rule])
        let value14 = try await placements(store, offers)
        XCTAssertNotEqual(value14, original.filter { offers.contains($0.key) })

        rule.isEnabled = false
        try await store.setSenderRules([rule])
        let value15 = try await placements(store, receipts + offers)
        XCTAssertEqual(value15, original, "a disabled rule does nothing")

        rule.isEnabled = true
        try await store.setSenderRules([rule])
        try await store.setSenderRules(previous) // Undo
        let value16 = try await store.senderRules()
        XCTAssertEqual(value16, [])
        let value17 = try await placements(store, receipts + offers)
        XCTAssertEqual(value17, original)
    }

    func testExcludedMessagesStayWhereTheyAre() async throws {
        let store = try await open()
        let (_, offers) = try await seedShop(store)
        let preview = try await store.previewSenderRules([SenderRule(account: account, scope: Self.offerList, action: .mute)])
        let keep = try XCTUnwrap(preview.items.first { $0.id == offers[1] })
        let rule = SenderRule(account: account, scope: Self.offerList, action: .mute, excluded: [keep.fingerprint])
        let second = try await store.previewSenderRules([rule])
        XCTAssertEqual(second.items.first { $0.id == offers[1] }?.isExcluded, true)
        XCTAssertFalse(second.items.first { $0.id == offers[1] }?.changes ?? true)
        try await store.setSenderRules([rule])
        let value18 = try await ids(store, .promotions)
        XCTAssertEqual(value18, [offers[1]])
    }

    // MARK: Keep latest

    func testKeepLatestOnlyMutesOlderDigestsAndFollowsNewArrivals() async throws {
        let store = try await open()
        let headers = ["List-ID: <weekly.news.example>", "List-Unsubscribe: <https://news.example/leave>"]
        var digests: [MailMessageID] = []
        for day in 1...3 {
            digests.append(try await store.ingest(Self.eml(from: "digest@news.example", subject: "Weekly digest \(day)", day: day * 7,
                                                           headers: headers), account: account).id)
        }
        let rule = SenderRule(account: account, scope: .list(id: "weekly.news.example", organisation: "news.example"), action: .keepLatestOnly)
        try await store.setSenderRules([rule])
        let value19 = try await ids(store, .subscriptions)
        XCTAssertEqual(value19, [digests[2]])

        let newer = try await store.ingest(Self.eml(from: "digest@news.example", subject: "Weekly digest 4", day: 28, headers: headers),
                                           account: account).id
        let value20 = try await ids(store, .subscriptions)
        XCTAssertEqual(value20, [newer], "the new digest replaces the last one")
        let value21 = try await store.verdict(of: digests[2])?.disposition
        XCTAssertEqual(value21, .muted)

        // An older one imported later never displaces the newest.
        let older = try await store.ingest(Self.eml(from: "digest@news.example", subject: "Weekly digest 0", day: 1, headers: headers),
                                           account: account).id
        let value22 = try await store.verdict(of: older)?.disposition
        XCTAssertEqual(value22, .muted)
        let value23 = try await ids(store, .subscriptions)
        XCTAssertEqual(value23, [newer])
    }

    // MARK: Safety

    func testRulesNeverTouchRiskyMailAndACopiedListIDDoesNotMatch() async throws {
        let store = try await open()
        _ = try await seedShop(store)
        // Same List-ID, sent from a lookalike organisation, asking for a password: phishing.
        let fake = try await store.ingest(Self.eml(from: "news@shop-example.test", subject: "Your account is locked, verify your password",
                                                   day: 9, headers: Self.offerHeaders + ["Reply-To: help@collect.example"],
                                                   body: "Verify your password now or lose access. Click here urgently."), account: account).id
        let inbox = SenderRule(account: account, scope: .list(id: "offers.shop.example", organisation: nil), action: .inbox)
        try await store.setSenderRules([inbox])
        let verdict = try await store.verdict(of: fake)
        XCTAssertEqual(verdict?.classification.risk.isQuarantined, true, "fixture: the copy is phishing")
        XCTAssertEqual(verdict?.home, .quarantine, "an inbox rule never pulls risky mail out of Quarantine")
        XCTAssertEqual(verdict?.senderRule, inbox.id)
        XCTAssertNotEqual(verdict?.disposition, .inbox, "rules never act on risky mail")

        // A rule made from the real list remembers its organisation: the copy is not matched.
        let scoped = SenderRule(account: account, scope: Self.offerList, action: .mute)
        try await store.setSenderRules([scoped])
        let value24 = try await store.verdict(of: fake)?.senderRule
        XCTAssertNil(value24)
    }

    func testRulesAreVirtualAndKeptInTheirOwnFile() async throws {
        let store = try await open()
        let (_, offers) = try await seedShop(store)
        let mailboxesBefore = try await store.effectiveMailboxes(of: offers[0])
        let flagsBefore = try await store.flags(of: offers[0])
        let rule = SenderRule(account: account, scope: Self.offerList, action: .mute)
        try await store.setSenderRules([rule])
        let value25 = try await store.effectiveMailboxes(of: offers[0])
        XCTAssertEqual(value25, mailboxesBefore, "muting never moves mail")
        let value26 = try await store.flags(of: offers[0])
        XCTAssertEqual(value26, flagsBefore)
        let file = locations.deviceFolder.appendingPathComponent("metadata/sender-rules.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "rules are user data in their own file")
        let corrections = locations.deviceFolder.appendingPathComponent("metadata/classification.json")
        XCTAssertFalse((try? String(contentsOf: corrections, encoding: .utf8))?.contains(rule.id) ?? false, "not mixed into the corrections")

        // They survive reopening and a rebuilt index.
        let reopened = try await MailStore.open(locations)
        try await reopened.rebuildIndex()
        while try await reopened.classifyPending() > 0 {}
        let value27 = try await reopened.verdict(of: offers[0])?.disposition
        XCTAssertEqual(value27, .muted)
    }

    func testAnIndexFromSchemaFourGainsTheRuleColumnsWithoutARebuild() async throws {
        do {
            let store = try await open()
            _ = try await seedShop(store)
        }
        let database = try SQLiteDatabase(url: locations.indexURL)
        try database.execute("DROP INDEX message_classes_by_rule; ALTER TABLE message_classes DROP COLUMN sender_rule; ALTER TABLE message_classes DROP COLUMN disposition")
        try database.setUserVersion(4)
        let reopened = try await MailStore.open(locations)
        let value28 = try await reopened.pendingClassificationCount()
        XCTAssertEqual(value28, 0, "verdicts kept: migrated, not rebuilt")
        try await reopened.setSenderRules([SenderRule(account: account, scope: Self.offerList, action: .mute)])
        let value29 = try await ids(reopened, .promotions)
        XCTAssertEqual(value29, [])
    }

    // MARK: Unsubscribe ledger

    func testUnsubscribeRequestsFailWhenMailKeepsComingAndConfirmWhenItStops() async throws {
        let store = try await open()
        _ = try await seedShop(store)
        let requested = Date(timeIntervalSince1970: 1_793_000_000) // 2026-10-27, before the shop's mail
        var stillSending = UnsubscribeRequest(account: account, scope: Self.offerList, method: "one-click",
                                              target: "https://unsubscribe.shop.example/u/abc", requestedAt: requested)
        stillSending.state = .pending
        var quiet = UnsubscribeRequest(account: account, scope: .list(id: "quiet.example", organisation: "quiet.example"),
                                       method: "mailto", target: "leave@quiet.example", requestedAt: requested)
        quiet.state = .pending
        try await store.saveUnsubscribeRequest(stillSending)
        try await store.saveUnsubscribeRequest(quiet)
        let changed = try await store.reviewUnsubscribeRequests(now: requested.addingTimeInterval(20 * 86_400))
        XCTAssertEqual(Set(changed.map(\.id)), [stillSending.id, quiet.id])
        let states = Dictionary(uniqueKeysWithValues: try await store.unsubscribeRequests().map { ($0.id, $0.state) })
        XCTAssertEqual(states[stillSending.id], .failed, "a request sent is not proof: mail still came")
        XCTAssertEqual(states[quiet.id], .confirmed)
    }

    // MARK: Helpers

    private func placements(_ store: MailStore, _ ids: [MailMessageID]) async throws -> [MailMessageID: SenderPlacement] {
        var result: [MailMessageID: SenderPlacement] = [:]
        for id in ids { if let verdict = try await store.verdict(of: id) { result[id] = MailStore.placement(verdict) } }
        return result
    }
}
