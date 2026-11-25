import XCTest
import MailClassifier
import MailCore
import MailStore

/// GKM-017 and GKM-018 in the app model, over the synthetic fixture corpus and a real store:
/// every view, the counts and the badge, corrections and rules from the reader, the search
/// chip, and which new mail notifies. Notifications are recorded instead of posted (there is no
/// notification centre without an app bundle); everything else is the real thing.
@MainActor
final class ClassificationAppTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let account = MailAccountID("corpus")
    private let history = MailAccountID("history")
    private let me = "alex.morgan@example.net"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gitmail-classes-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    // MARK: Corpus

    private struct Expectations: Decodable {
        struct Context: Decodable { var knownCorrespondents: [String]; var trustedSenderDomains: [String] }
        struct Fixture: Decodable {
            var file: String
            var purpose: MailPurpose
            var risk: MailRisk
            var urgency: MailUrgency
            var providerVerdict: String?
            var providerFolders: [String]?
            var home: MailCategory { MailCategory.home(purpose: purpose, risk: risk, urgency: urgency) }
        }
        var context: Context
        var fixtures: [Fixture]
    }

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../swift/GitKittieMailKit/Sources/MailTestSupport/Fixtures").standardizedFileURL

    private static func eml(from: String, to: String, subject: String, date: Date = Date(), id: String = UUID().uuidString,
                            headers: [String] = [], body: String = "Hello") -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let lines = ["From: \(from)", "To: \(to)", "Subject: \(subject)", "Date: \(formatter.string(from: date))", "Message-ID: <\(id)@example.net>"]
            + headers + ["MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8", "", body, ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// The corpus in a store, with the mailbox history its expectations assume (mail you sent,
    /// mail that passed your provider's authentication over a week), classified as it arrived.
    private func seedCorpus() async throws -> (Expectations, [String: MailMessageID]) {
        let expectations = try JSONDecoder().decode(Expectations.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("expectations.json")))
        let store = try await MailStore.open(locations, classification: ClassificationOptions(trustedAuthServIDs: [account: ["mx.example.net"],
                                                                                                                 history: ["mx.example.net"]]))
        try await store.save(MailAccount(id: account, displayName: "Corpus", address: me))
        try await store.save(MailAccount(id: history, displayName: "History", address: me))
        for person in expectations.context.knownCorrespondents {
            try await store.ingest(Self.eml(from: me, to: person, subject: "Plans", date: Date(timeIntervalSince1970: 1_780_000_000)), account: history)
        }
        for domain in expectations.context.trustedSenderDomains {
            for offset: TimeInterval in [0, 8 * 86_400] {
                try await store.ingest(Self.eml(from: "accounts@\(domain)", to: me, subject: "Account statement",
                                                date: Date(timeIntervalSince1970: 1_780_000_000 + offset),
                                                headers: ["Authentication-Results: mx.example.net; dmarc=pass header.from=\(domain)"]), account: history)
            }
        }
        var ids: [String: MailMessageID] = [:]
        for (n, fixture) in expectations.fixtures.enumerated() {
            let folder = fixture.providerFolders?.first ?? (fixture.providerVerdict == "spam" ? "Junk" : "INBOX")
            ids[fixture.file] = try await store.ingest(Data(contentsOf: Self.fixtures.appendingPathComponent(fixture.file)), account: account,
                                                       remote: RemoteLocation(mailbox: folder, uidValidity: 1, uid: UInt32(n + 1))).id
        }
        return (expectations, ids)
    }

    private func openModel(poster: RecordingPoster? = nil) async -> AppModel {
        let model = AppModel(locations: locations, notifications: poster)
        await model.open()
        await model.attention.waitForClassification()
        return model
    }

    /// The threads a view lists, as the fixtures' thread ids.
    private func threadIDs(_ model: AppModel) -> Set<String> { Set(model.browser.rows.map(\.threadID)) }

    func testTheWindowOpensOnFocusedAndEveryViewListsExactlyItsMail() async throws {
        let (expectations, ids) = try await seedCorpus()
        let model = await openModel()
        XCTAssertEqual(model.selection, .category(.focused), "Focused is where the window opens")
        XCTAssertEqual(model.attention.pendingClassification, 0)

        // Which thread each fixture is in, from All Mail.
        await model.select(.allMail)
        let all = try await model.mailStore!.search(SearchQuery(account: account), limit: 500)
        let threadOf = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.threadID) })
        XCTAssertEqual(Set(all.map(\.id)), Set(ids.values), "All Mail always shows everything")

        for category in MailCategory.allCases {
            await model.select(.category(category))
            await model.select(.account(account)) // and back, so the scope reloads cleanly
            await model.select(.category(category))
            // Nothing is read yet, so every receipt is in Focused too (MAIL-076).
            let members = expectations.fixtures.filter {
                $0.home == category || (category.purpose == $0.purpose && $0.home != .quarantine)
                    || (category == .focused && $0.home == .transactions && $0.purpose == .transaction)
            }
            let expectedThreads = Set(members.compactMap { ids[$0.file].flatMap { threadOf[$0] } })
            // Rows from the history account are mail too; compare the corpus's threads only.
            let corpusThreads = threadIDs(model).intersection(Set(threadOf.values))
            XCTAssertEqual(corpusThreads, expectedThreads, "\(category)")
            XCTAssertEqual(model.browser.scope, .category(category))
        }

        // Uncertain mail stays visible; promotions are not in Focused.
        await model.select(.category(.focused))
        let focused = threadIDs(model)
        for fixture in expectations.fixtures where fixture.purpose == .unknown && !fixture.risk.isQuarantined {
            XCTAssertTrue(focused.contains(threadOf[ids[fixture.file]!]!), "\(fixture.file) is visible in Focused")
        }
        // A promotion is only in Focused through a conversation in its thread (a reply to a campaign).
        let focusedMessageThreads = Set(expectations.fixtures.filter { $0.home == .focused }.compactMap { threadOf[ids[$0.file]!] })
        for fixture in expectations.fixtures where fixture.home == .promotions {
            let thread = threadOf[ids[fixture.file]!]!
            XCTAssertEqual(focused.contains(thread), focusedMessageThreads.contains(thread), fixture.file)
        }
        XCTAssertTrue(focused.contains(threadOf[ids["conv-reply-to-campaign.eml"]!]!), "the reply to a campaign is a conversation")
    }

    func testCountsSeparateUnreadFromAttentionAndPromotionsStayOffTheBadge() async throws {
        let (_, ids) = try await seedCorpus()
        let model = await openModel()
        let store = try XCTUnwrap(model.mailStore)
        let counts = try await store.categoryCounts()
        for category in MailCategory.allCases { XCTAssertEqual(model.attention.count(category), counts[category] ?? CategoryCount()) }
        XCTAssertEqual(model.attention.badgeCount, counts[.focused]?.unread)
        XCTAssertGreaterThan(model.attention.count(.promotions).unread, 0)

        // Reading a promotion changes its view's unread count, never the badge.
        let badge = model.attention.badgeCount
        try await store.setFlags(MessageFlags(seen: true), for: XCTUnwrap(ids["promo-sale-en.eml"]))
        await model.refreshAfterSync()
        XCTAssertEqual(model.attention.badgeCount, badge)
        XCTAssertEqual(model.attention.count(.promotions).unread, (counts[.promotions]?.unread ?? 0) - 1)
        // Reading a conversation does.
        try await store.setFlags(MessageFlags(seen: true), for: XCTUnwrap(ids["conv-personal-en-dinner.eml"]))
        await model.refreshAfterSync()
        XCTAssertEqual(model.attention.badgeCount, badge - 1)

        // An account with notifications off is off the badge too.
        await model.attention.setLevel(.off, for: account, accounts: model.accounts)
        let historyFocusedUnread = try await store.categoryCounts(account: history)[.focused]?.unread ?? 0
        XCTAssertEqual(model.attention.badgeCount, historyFocusedUnread)
    }

    /// GKM-018, answered by Sil (MAIL-076): a receipt is in Focused until it is read, then only
    /// in Transactions. Reading it in Focused keeps its row in place while it is open; it is gone
    /// from Focused once the list loads again, and Transactions still lists it.
    func testAReceiptStaysInFocusedUntilReadThenOnlyInTransactions() async throws {
        let (_, ids) = try await seedCorpus()
        let model = await openModel()
        let receipt = try XCTUnwrap(ids["txn-receipt-en.eml"])
        let store = try XCTUnwrap(model.mailStore)
        let verdict = try await store.verdict(of: receipt)
        XCTAssertEqual(verdict?.home, .transactions)
        let unreadBefore = model.attention.count(.focused).unread

        await model.select(.category(.focused))
        let row = try XCTUnwrap(model.browser.rows.first { $0.latest.id == receipt }, "unread: in Focused")
        await model.browser.select(row.id)
        let kept = try XCTUnwrap(model.browser.rows.first { $0.id == row.id }, "the open row stays while it is read")
        XCTAssertFalse(kept.isUnread)
        XCTAssertEqual(model.browser.selectedRowID, row.id)
        await model.refreshAfterSync()
        XCTAssertEqual(model.attention.count(.focused).unread, unreadBefore - 1)

        await model.select(.category(.transactions))
        XCTAssertTrue(model.browser.rows.contains { $0.latest.id == receipt })
        await model.select(.category(.focused))
        XCTAssertFalse(model.browser.rows.contains { $0.latest.id == receipt }, "read: only in Transactions")
    }

    func testTheSearchChipNarrowsToACategory() async throws {
        _ = try await seedCorpus()
        let model = await openModel()
        await model.select(.allMail)
        var filters = SearchFilters()
        filters.category = .promotions
        filters.account = account
        await model.browser.setFilters(filters)
        XCTAssertTrue(model.browser.isSearching)
        let shown = model.browser.rows.map(\.latest.id)
        let promotions = try await model.mailStore!.search(SearchQuery(account: account, category: .promotions)).map(\.id)
        XCTAssertEqual(Set(shown), Set(promotions))
        XCTAssertFalse(shown.isEmpty)
        await model.browser.search("category:quarantine")
        XCTAssertEqual(model.browser.query.category, .promotions, "the chip wins over the typed category")
    }

    // MARK: Corrections

    func testMovingAMessageAppliesAtOnceAndARuleIsMadeOnlyWhenChosen() async throws {
        let (_, ids) = try await seedCorpus()
        let model = await openModel()
        let promo = try XCTUnwrap(ids["promo-rabatt-de.eml"])
        let store = try XCTUnwrap(model.mailStore)

        await model.select(.category(.promotions))
        let row = try XCTUnwrap(model.browser.rows.first { $0.latest.id == promo })
        await model.browser.select(row.id)
        XCTAssertEqual(model.browser.openThread?.messages.last?.verdict?.home, .promotions)
        XCTAssertFalse(VerdictText.reasons(try XCTUnwrap(model.browser.openThread?.messages.last?.verdict)).isEmpty)

        await model.move(promo, to: .conversation)
        let verdict = try XCTUnwrap(model.browser.openThread?.messages.last?.verdict)
        XCTAssertEqual(verdict.home, .focused, "the open message shows the correction at once")
        XCTAssertEqual(VerdictText.summary(verdict), "In Focused because you said so.")
        XCTAssertFalse(model.browser.rows.contains { $0.latest.id == promo }, "it left Promotions")
        let correction = await model.correction(of: promo)
        XCTAssertEqual(correction?.purpose, .conversation)
        let rulesBefore = await model.classificationRules()
        XCTAssertEqual(rulesBefore, [], "no rule unless you choose one")

        // The same campaign's next message is untouched until you make the rule.
        let next = try await store.ingest(Self.eml(from: "Eichenhof Buchladen <angebote@eichenhof.example.com>", to: me,
                                                   subject: "Nur heute: 30 % Rabatt", headers: ["List-ID: <angebote.eichenhof.example.com>"]),
                                          account: account).id
        let before = try await store.verdict(of: next)
        XCTAssertEqual(before?.home, .promotions)
        await model.addRule(.list(try XCTUnwrap(verdict.listID)), purpose: .subscription, account: account)
        let after = try await store.verdict(of: next)
        XCTAssertEqual(after?.classification.purpose, .subscription)
        let rule = await model.rule(for: try XCTUnwrap(after))
        XCTAssertNotNil(rule)

        await model.undoCorrection(promo)
        let undone = try await store.verdict(of: promo)
        XCTAssertEqual(undone?.classification.purpose, .subscription, "without the correction, your list rule decides")
    }

    func testNotPhishingAndReportPhishingChangeOnlyThatMessage() async throws {
        let (_, ids) = try await seedCorpus()
        let model = await openModel()
        let phish = try XCTUnwrap(ids["phish-lookalike-domain.eml"])
        let dinner = try XCTUnwrap(ids["conv-personal-en-dinner.eml"])
        await model.clearRisk(phish)
        let cleared = try await model.mailStore!.verdict(of: phish)
        XCTAssertEqual(cleared?.classification.risk, MailRisk.none)
        XCTAssertNotEqual(cleared?.home, .quarantine)
        await model.markPhishing(dinner)
        let reported = try await model.mailStore!.verdict(of: dinner)
        XCTAssertEqual(reported?.home, .quarantine)
        XCTAssertNil(model.actionError)
    }

    // MARK: Notifications

    func testOnlyNewFocusedMailNotifiesAndSettingsAreRespected() async throws {
        _ = try await seedCorpus()
        let poster = RecordingPoster(permission: .notAsked, answer: .allowed)
        let model = await openModel(poster: poster)
        let store = try XCTUnwrap(model.mailStore)
        let existing = await poster.posted
        XCTAssertEqual(existing, [], "mail that was already there never notifies")

        let list = ["List-ID: <walkers.lists.example.org>", "List-Post: <mailto:walkers@lists.example.org>"]
        try await store.ingest(Self.eml(from: "Jo Lee <jo.lee@example.org>", to: me, subject: "Dinner tonight?"), account: account)
        try await store.ingest(Self.eml(from: "offers@shop.example.com", to: me, subject: "50% off everything",
                                        headers: ["List-Unsubscribe: <https://shop.example.com/u>"]), account: account)
        try await store.ingest(Self.eml(from: "Old Friend <old.friend@example.org>", to: me, subject: "From the archive",
                                        date: Date(timeIntervalSinceNow: -5 * 86_400)), account: account)
        try await store.ingest(Self.eml(from: "Ravi <ravi.patel@example.org>", to: me, subject: "Ridge trail Saturday", headers: list), account: account)
        await model.refreshAfterSync()
        var posted = await poster.posted
        XCTAssertEqual(posted.map(\.title).sorted(), ["Jo Lee", "Ravi"], "focused, new, unread only; promotions and history stay silent")
        let asked = await poster.requests
        XCTAssertEqual(asked, 1, "permission is asked once, when there is something to say")
        XCTAssertEqual(model.attention.permission, .allowed)

        // A muted list and an account with notifications off stay silent.
        await poster.reset()
        await model.attention.setLevel(.muted, list: "walkers.lists.example.org", account: account, accounts: model.accounts)
        try await store.ingest(Self.eml(from: "Ravi <ravi.patel@example.org>", to: me, subject: "Re: Ridge trail", headers: list), account: account)
        await model.refreshAfterSync()
        posted = await poster.posted
        XCTAssertEqual(posted, [])
        await model.attention.setLevel(.off, for: account, accounts: model.accounts)
        try await store.ingest(Self.eml(from: "Jo Lee <jo.lee@example.org>", to: me, subject: "Still on?"), account: account)
        await model.refreshAfterSync()
        posted = await poster.posted
        XCTAssertEqual(posted, [])

        // Settings are kept on this device.
        let reloaded = try NotificationSettings.load(deviceFolder: locations.deviceFolder)
        XCTAssertEqual(reloaded.level(account), .off)
        XCTAssertEqual(reloaded.level(list: "walkers.lists.example.org", account: account), .muted)

        // Many at once become one summary.
        await model.attention.setLevel(.focused, for: account, accounts: model.accounts)
        for n in 0..<5 { try await store.ingest(Self.eml(from: "p\(n).person@example.org", to: me, subject: "Hi \(n)"), account: account) }
        await model.refreshAfterSync()
        posted = await poster.posted
        XCTAssertEqual(posted, [MailNotification(message: nil, title: "GitKittie Mail", body: "5 new messages")])
    }

    func testNothingIsPostedWhenNotificationsAreNotAllowed() async throws {
        let poster = RecordingPoster(permission: .notAsked, answer: .denied)
        let model = await openModel(poster: poster)
        try await model.mailStore!.ingest(Self.eml(from: "Jo Lee <jo.lee@example.org>", to: me, subject: "Dinner?"), account: account)
        await model.refreshAfterSync()
        let posted = await poster.posted
        XCTAssertEqual(posted, [])
        XCTAssertEqual(model.attention.permission, .denied)
        try await model.mailStore!.ingest(Self.eml(from: "Jo Lee <jo.lee@example.org>", to: me, subject: "Dinner??"), account: account)
        await model.refreshAfterSync()
        let asked = await poster.requests
        XCTAssertEqual(asked, 1, "a refusal is respected, not asked again")
    }

    func testImportedMailDoesNotNotify() async throws {
        let poster = RecordingPoster(permission: .allowed, answer: .allowed)
        let model = await openModel(poster: poster)
        let file = root.appendingPathComponent("new.eml")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.eml(from: "Jo Lee <jo.lee@example.org>", to: me, subject: "Dinner?").write(to: file)
        await model.importMessages(from: [file])
        await model.refreshAfterSync()
        let posted = await poster.posted
        XCTAssertEqual(posted, [])
    }
}

/// Records what would be posted, and answers the permission question as told.
actor RecordingPoster: MailNotificationPosting {
    private var current: NotificationPermission
    private let answer: NotificationPermission
    private(set) var posted: [MailNotification] = []
    private(set) var requests = 0

    init(permission: NotificationPermission, answer: NotificationPermission) {
        current = permission
        self.answer = answer
    }

    func permission() async -> NotificationPermission { current }
    func requestPermission() async throws -> NotificationPermission {
        requests += 1
        current = answer
        return answer
    }
    func post(_ notification: MailNotification) async throws { posted.append(notification) }
    func reset() { posted = [] }
}
