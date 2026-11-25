import XCTest
import MailClassifier
import MailCore
import MailTestSupport
@testable import MailStore

/// GKM-017 in the store: every message classified as it is stored, read-only; views over the
/// corpus; corrections and rules that apply at once and survive reopening, rebuilds and rule-set
/// upgrades; what the mailbox history teaches (correspondents, trusted domains).
final class StoreClassificationTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let account = MailAccountID("corpus")
    private let seeds = MailAccountID("history")
    private let me = "alex.morgan@example.net"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("classes-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var options: ClassificationOptions {
        ClassificationOptions(trustedAuthServIDs: [account: ["mx.example.net"], seeds: ["mx.example.net"]])
    }

    private func open() async throws -> MailStore {
        try await MailStore.open(locations, classification: options)
    }

    private static func eml(from: String, to: String, subject: String, date: String = "Mon, 02 Nov 2026 10:00:00 +0000",
                            id: String = UUID().uuidString, headers: [String] = [], body: String = "Hello") -> Data {
        let lines = ["From: \(from)", "To: \(to)", "Subject: \(subject)", "Date: \(date)", "Message-ID: <\(id)@example.net>"]
            + headers + ["MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8", "", body, ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// The mailbox history the corpus assumes (expectations.json `context`), built the way the
    /// app learns it: mail you sent, and mail that passed trusted authentication over a week.
    private func seedHistory(_ store: MailStore) async throws -> FixtureExpectations {
        let expectations = try MailFixtures.expectations()
        try await store.save(MailAccount(id: account, displayName: "Corpus", address: me))
        try await store.save(MailAccount(id: seeds, displayName: "History", address: me))
        for (n, person) in expectations.context.knownCorrespondents.enumerated() {
            try await store.ingest(Self.eml(from: me, to: person, subject: "Plans", id: "sent-\(n)"), account: seeds)
        }
        for domain in expectations.context.trustedSenderDomains {
            for (n, date) in ["Mon, 02 Nov 2026 10:00:00 +0000", "Tue, 10 Nov 2026 10:00:00 +0000"].enumerated() {
                let auth = "Authentication-Results: mx.example.net; spf=pass; dkim=pass header.d=\(domain); dmarc=pass header.from=\(domain)"
                try await store.ingest(Self.eml(from: "accounts@\(domain)", to: me, subject: "Account statement", date: date,
                                                id: "auth-\(n)-\(domain)", headers: [auth]), account: seeds)
            }
        }
        let trusted = try await store.trustedSenderDomains()
        XCTAssertEqual(trusted, Set(expectations.context.trustedSenderDomains))
        return expectations
    }

    /// Stores the corpus into `account`: the junk-folder fixture into the provider's Junk folder.
    private func ingestCorpus(_ store: MailStore, _ expectations: FixtureExpectations) async throws -> [String: MailMessageID] {
        var ids: [String: MailMessageID] = [:]
        for (n, fixture) in expectations.fixtures.enumerated() {
            let data = try Data(contentsOf: XCTUnwrap(MailFixtures.directory?.appendingPathComponent(fixture.file)))
            // Over IMAP a provider's spam verdict arrives as the message being in its Junk folder.
            let folder = fixture.providerFolders?.first ?? (fixture.providerVerdict == "spam" ? "Junk" : "INBOX")
            ids[fixture.file] = try await store.ingest(data, account: account, remote: RemoteLocation(mailbox: folder, uidValidity: 1, uid: UInt32(n + 1))).id
        }
        return ids
    }

    // MARK: Corpus and views

    func testEveryFixtureIsClassifiedAsItIsStored() async throws {
        let store = try await open()
        let expectations = try await seedHistory(store)
        let ids = try await ingestCorpus(store, expectations)
        var correct = 0
        for fixture in expectations.fixtures {
            let id = try XCTUnwrap(ids[fixture.file])
            let verdict = try await XCTUnwrapAsync(await store.verdict(of: id), fixture.file)
            let c = verdict.classification
            XCTAssertEqual(c.ruleSetVersion, MailClassifier.ruleSetVersion)
            XCTAssertFalse(c.reasons.isEmpty, fixture.file)
            if (c.purpose, c.risk, c.urgency) == (fixture.purpose, fixture.risk, fixture.urgency) {
                correct += 1
            } else {
                XCTFail("\(fixture.file): expected \(fixture.purpose)/\(fixture.risk)/\(fixture.urgency), got \(c.purpose)/\(c.risk)/\(c.urgency) "
                        + c.reasons.map(\.rawValue).joined(separator: ","))
            }
        }
        print("Store corpus: \(correct)/\(expectations.fixtures.count) fixtures with purpose, risk and urgency as expected")
        let pending = try await store.pendingClassificationCount()
        XCTAssertEqual(pending, 0)
    }

    /// The sync stores a fetched batch in one write (GKM-035): every message in it gets the
    /// verdict, home and arrival number the one-by-one path gives, and joins a rule-set upgrade.
    func testASyncedBatchIsClassifiedExactlyAsMessagesStoredOneByOne() async throws {
        let single = try await open()
        let expectations = try await seedHistory(single)
        let singleIDs = try await ingestCorpus(single, expectations)

        locations = StoreLocations(mailFolder: root.appendingPathComponent("Batch/Mail"),
                                   deviceFolder: root.appendingPathComponent("Batch/Support/Mail"))
        let batched = try await open()
        _ = try await seedHistory(batched)
        let start = try await batched.latestArrival()
        var messages: [SyncedMessage] = []
        for (n, fixture) in expectations.fixtures.enumerated() {
            let data = try Data(contentsOf: XCTUnwrap(MailFixtures.directory?.appendingPathComponent(fixture.file)))
            let folder = fixture.providerFolders?.first ?? (fixture.providerVerdict == "spam" ? "Junk" : "INBOX")
            messages.append(SyncedMessage(eml: data, remote: RemoteLocation(mailbox: folder, uidValidity: 1, uid: UInt32(n + 1)),
                                          receivedAt: Date(), flags: MailMessageFlags()))
        }
        let outcomes = try await batched.storeSynced(messages, account: account)
        XCTAssertTrue(outcomes.allSatisfy { if case .stored = $0 { return true }; return false }, "\(outcomes)")

        for (fixture, outcome) in zip(expectations.fixtures, outcomes) {
            let one = try await XCTUnwrapAsync(await single.verdict(of: XCTUnwrap(singleIDs[fixture.file])), fixture.file)
            let batch = try await XCTUnwrapAsync(await batched.verdict(of: outcome.id), fixture.file)
            XCTAssertEqual(batch.classification.ruleSetVersion, MailClassifier.ruleSetVersion)
            XCTAssertEqual(batch.classification.purpose, one.classification.purpose, fixture.file)
            XCTAssertEqual(batch.classification.risk, one.classification.risk, fixture.file)
            XCTAssertEqual(batch.classification.urgency, one.classification.urgency, fixture.file)
            XCTAssertEqual(batch.classification.reasons, one.classification.reasons, fixture.file)
            XCTAssertEqual(batch.home, one.home, fixture.file)
            XCTAssertEqual(batch.isCorrected, one.isCorrected, fixture.file)
        }
        let pending = try await batched.pendingClassificationCount()
        XCTAssertEqual(pending, 0)
        let arrivals = try await batched.arrivals(after: start)
        XCTAssertEqual(arrivals.map(\.id), outcomes.map(\.id), "each arrives once, in batch order")

        // A new rule set reclassifies batch-stored mail like any other, keeping the arrivals.
        let total = try await batched.messageCount()
        try await batched.markVerdictsAsRuleSetForTesting("gkm-rules-1")
        let stale = try await batched.pendingClassificationCount()
        XCTAssertEqual(stale, total)
        while try await batched.classifyPending() > 0 {}
        for outcome in outcomes {
            let verdict = try await batched.verdict(of: outcome.id)
            XCTAssertEqual(verdict?.classification.ruleSetVersion, MailClassifier.ruleSetVersion)
        }
        let again = try await batched.arrivals(after: start)
        XCTAssertEqual(again.map(\.sequence), arrivals.map(\.sequence))
    }

    func testEveryViewShowsExactlyItsMessagesAndAllMailShowsEverything() async throws {
        let store = try await open()
        let expectations = try await seedHistory(store)
        let ids = try await ingestCorpus(store, expectations)
        let fileOf = Dictionary(uniqueKeysWithValues: ids.map { ($0.value, $0.key) })

        func files(_ category: MailCategory?) async throws -> Set<String> {
            Set(try await store.search(SearchQuery(account: account, category: category), limit: 500).compactMap { fileOf[$0.id] })
        }
        let all = try await files(nil)
        XCTAssertEqual(all, Set(expectations.fixtures.map(\.file)), "All Mail shows every message")

        var union = Set<String>()
        for category in MailCategory.allCases {
            let expected = Set(expectations.fixtures.filter { fixture in
                let home = MailCategory.home(purpose: fixture.purpose, risk: fixture.risk, urgency: fixture.urgency)
                // Nothing is read yet, so every receipt is in Focused too (MAIL-076).
                let unreadReceipt = category == .focused && home == .transactions && fixture.purpose == .transaction
                return home == category || (category.purpose == fixture.purpose && home != .quarantine) || unreadReceipt
            }.map(\.file))
            let shown = try await files(category)
            XCTAssertEqual(shown, expected, "\(category)")
            union.formUnion(shown)
        }
        XCTAssertEqual(union, all, "every message is in some view")

        // The acceptance criteria, said plainly.
        let focused = try await files(.focused)
        for fixture in expectations.fixtures where fixture.purpose == .unknown && !fixture.risk.isQuarantined {
            XCTAssertTrue(focused.contains(fixture.file), "\(fixture.file): uncertain mail stays visible in Focused")
        }
        for fixture in expectations.fixtures where fixture.purpose == .promotion {
            XCTAssertFalse(focused.contains(fixture.file), fixture.file)
        }
        let quarantine = try await files(.quarantine)
        XCTAssertTrue(quarantine.contains("phish-spoofed-trusted-sender.eml"))
        let transactions = try await files(.transactions)
        XCTAssertTrue(transactions.contains("txn-payment-failed-en.eml"), "actionable transactions are in Transactions too")
        XCTAssertTrue(focused.contains("txn-payment-failed-en.eml"))
        XCTAssertTrue(focused.contains("txn-receipt-en.eml"), "an unread receipt is in Focused (MAIL-076)")

        // Threads and the search syntax use the same filter.
        let threadFiles = Set(try await store.threads(SearchQuery(account: account, category: .promotions), limit: 500).map(\.latest.id).compactMap { fileOf[$0] })
        let promotionFiles = try await files(.promotions)
        XCTAssertEqual(threadFiles, promotionFiles)
        XCTAssertEqual(SearchQuery.parse("category:promotion sale").category, .promotions)
        XCTAssertEqual(SearchQuery.parse("category:spam").category, .quarantine)
        XCTAssertNil(SearchQuery.parse("category:nonsense").category)

        // Counts follow the views; unread is separate.
        let counts = try await store.categoryCounts(account: account)
        for category in MailCategory.allCases {
            let shown = try await files(category)
            XCTAssertEqual(counts[category]?.total ?? 0, shown.count, "\(category)")
            XCTAssertEqual(counts[category]?.unread ?? 0, shown.count, "\(category): nothing read yet")
        }
        let someFocused = try XCTUnwrap(ids["conv-personal-en-dinner.eml"])
        try await store.setFlags(MessageFlags(seen: true), for: someFocused)
        let after = try await store.categoryCounts(account: account)
        XCTAssertEqual(after[.focused]?.unread, (counts[.focused]?.unread ?? 0) - 1)
        XCTAssertEqual(after[.focused]?.total, counts[.focused]?.total)

        // GKM-018, answered by Sil: a receipt stays in Focused until it is read, then it is only
        // in Transactions. Its home stays Transactions throughout.
        let receipt = try XCTUnwrap(ids["txn-receipt-en.eml"])
        let receiptVerdict = try await store.verdict(of: receipt)
        XCTAssertEqual(receiptVerdict?.home, .transactions)
        try await store.setFlags(MessageFlags(seen: true), for: receipt)
        let focusedAfterReading = try await files(.focused)
        XCTAssertFalse(focusedAfterReading.contains("txn-receipt-en.eml"), "read: only in Transactions")
        let transactionsAfterReading = try await files(.transactions)
        XCTAssertTrue(transactionsAfterReading.contains("txn-receipt-en.eml"))
        let readReceipt = try await store.categoryCounts(account: account)
        XCTAssertEqual(readReceipt[.focused]?.total, (after[.focused]?.total ?? 0) - 1)
        XCTAssertEqual(readReceipt[.focused]?.unread, (after[.focused]?.unread ?? 0) - 1)
        XCTAssertEqual(readReceipt[.transactions]?.total, after[.transactions]?.total)
        XCTAssertEqual(readReceipt[.transactions]?.unread, (after[.transactions]?.unread ?? 0) - 1)
        let threadsInFocused = Set(try await store.threads(SearchQuery(account: account, category: .focused), limit: 500)
            .map(\.latest.id).compactMap { fileOf[$0] })
        XCTAssertFalse(threadsInFocused.contains("txn-receipt-en.eml"))
        try await store.setFlags(MessageFlags(seen: false), for: receipt)
        let focusedWhenUnreadAgain = try await files(.focused)
        XCTAssertTrue(focusedWhenUnreadAgain.contains("txn-receipt-en.eml"), "marked unread: back in Focused")
    }

    func testUnclassifiedMailCountsAsFocusedUntilTheBackgroundPassClassifiesIt() async throws {
        let store = try await open()
        let promo = try Data(contentsOf: XCTUnwrap(MailFixtures.directory?.appendingPathComponent("promo-sale-en.eml")))
        let id = try await store.ingest(promo, account: account).id
        // As an index from before GKM-017, or after a rebuild, would have it.
        try await store.dropVerdictsForTesting()
        let before = try await store.search(SearchQuery(category: .focused)).map(\.id)
        XCTAssertEqual(before, [id], "no verdict yet: visible in Focused")
        let pending = try await store.pendingClassificationCount()
        XCTAssertEqual(pending, 1)
        let done = try await store.classifyPending()
        XCTAssertEqual(done, 1)
        let afterFocused = try await store.search(SearchQuery(category: .focused))
        XCTAssertEqual(afterFocused, [])
        let promotions = try await store.search(SearchQuery(category: .promotions)).map(\.id)
        XCTAssertEqual(promotions, [id])
        let again = try await store.classifyPending()
        XCTAssertEqual(again, 0)
    }

    func testARebuiltIndexIsClassifiedAgainWithTheSameResult() async throws {
        let store = try await open()
        let expectations = try await seedHistory(store)
        let ids = try await ingestCorpus(store, expectations)
        var before: [MailMessageID: MailCategory] = [:]
        for id in ids.values { before[id] = try await store.verdict(of: id)?.home }
        try await store.rebuildIndex()
        while try await store.classifyPending(limit: 25) > 0 {}
        for id in ids.values {
            let home = try await store.verdict(of: id)?.home
            XCTAssertEqual(home, before[id])
        }
    }

    // MARK: Index migration

    /// One linear path into schema 4: from 3 (Spaces, GKM-022) the classification tables are
    /// added in place and the mail is classified in the background; from 1 and 2 the index is
    /// rebuilt as before. Either way your corrections are kept.
    func testAnOlderIndexReachesSchemaFourAndKeepsCorrections() async throws {
        for version in [3, 2, 1] {
            try? FileManager.default.removeItem(at: root)
            var store = try await open()
            let data = try Data(contentsOf: XCTUnwrap(MailFixtures.directory?.appendingPathComponent("promo-sale-en.eml")))
            let id = try await store.ingest(data, account: account).id
            try await store.correct(id, purpose: .conversation)
            try await store.downgradeIndexForTesting(to: version)
            store = try await open()
            let count = try await store.messageCount()
            XCTAssertEqual(count, 1, "version \(version)")
            let schema = try await store.indexVersionForTesting()
            XCTAssertEqual(schema, MailIndex.schemaVersion, "version \(version)")
            try await store.classifyPending()
            let verdict = try await store.verdict(of: id)
            XCTAssertEqual(verdict?.classification.purpose, .conversation, "version \(version): the correction survives")
            XCTAssertEqual(verdict?.home, .focused)
        }
    }

    // MARK: Read-only

    func testClassifyingAndCorrectingNeverTouchesTheProviderStateOrTheMailFolder() async throws {
        let store = try await open()
        let expectations = try await seedHistory(store)
        let ids = try await ingestCorpus(store, expectations)
        for (n, id) in ids.values.sorted().enumerated() {
            try await store.setFlags([id: MailMessageFlags(seen: n % 2 == 0, flagged: n % 3 == 0, keywords: ["$Label\(n % 2)"])], account: account)
        }
        let folderBefore = try snapshot(locations.mailFolder)
        let flagsBefore = try await store.flags(of: Array(ids.values), account: account)
        var locationsBefore: [MailMessageID: [RemoteLocation]] = [:]
        for id in ids.values { locationsBefore[id] = try await store.remoteLocations(of: id, account: account) }
        let foldersBefore = try await store.folders(account: account)

        let promo = try XCTUnwrap(ids["promo-sale-en.eml"])
        let phish = try XCTUnwrap(ids["phish-lookalike-domain.eml"])
        try await store.correct(promo, purpose: .conversation)
        try await store.correct(phish, risk: MailRisk.none)
        try await store.addRule(.list("offers.larkspur.example.com"), purpose: .subscription, account: account)
        try await store.dropVerdictsForTesting()
        while try await store.classifyPending(limit: 20) > 0 {}

        let folderAfter = try snapshot(locations.mailFolder)
        XCTAssertEqual(folderAfter, folderBefore, "no file in the mail folder changed, appeared or went away")
        let flagsAfter = try await store.flags(of: Array(ids.values), account: account)
        XCTAssertEqual(flagsAfter, flagsBefore, "provider flags untouched")
        for id in ids.values {
            let now = try await store.remoteLocations(of: id, account: account)
            XCTAssertEqual(now, locationsBefore[id], "provider folders untouched")
        }
        let foldersAfter = try await store.folders(account: account)
        XCTAssertEqual(foldersAfter, foldersBefore)
    }

    private func snapshot(_ folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            result[url.path.replacingOccurrences(of: folder.path, with: "")] = try Data(contentsOf: url)
        }
        return result
    }

    // MARK: Corrections

    func testACorrectionAppliesAtOnceAndSurvivesReopenRebuildAndARuleSetUpgrade() async throws {
        var store = try await open()
        let data = try Data(contentsOf: XCTUnwrap(MailFixtures.directory?.appendingPathComponent("promo-sale-en.eml")))
        let id = try await store.ingest(data, account: account).id
        let before = try await store.verdict(of: id)
        XCTAssertEqual(before?.home, .promotions)

        let corrected = try await store.correct(id, purpose: .conversation)
        XCTAssertEqual(corrected?.classification.purpose, .conversation, "applied immediately")
        XCTAssertEqual(corrected?.home, .focused)
        XCTAssertEqual(corrected?.isCorrected, true)
        XCTAssertTrue(corrected?.classification.reasons.contains(.userOverride) == true)

        store = try await open()
        let reopened = try await store.verdict(of: id)
        XCTAssertEqual(reopened?.classification.purpose, .conversation, "kept after reopening")

        try await store.rebuildIndex()
        try await store.classifyPending()
        let rebuilt = try await store.verdict(of: id)
        XCTAssertEqual(rebuilt?.classification.purpose, .conversation, "kept through a rebuild")

        // A rule-set upgrade: every stored verdict is from an older rule set and runs again.
        try await store.markVerdictsAsRuleSetForTesting("gkm-rules-1")
        let stale = try await store.pendingClassificationCount()
        XCTAssertEqual(stale, 1)
        try await store.classifyPending()
        let upgraded = try await store.verdict(of: id)
        XCTAssertEqual(upgraded?.classification.purpose, .conversation, "kept through a rule-set upgrade")
        XCTAssertEqual(upgraded?.classification.ruleSetVersion, MailClassifier.ruleSetVersion)

        let file = ClassificationMetadata.url(in: locations.deviceFolder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "corrections are device metadata")
        XCTAssertFalse(file.path.hasPrefix(locations.mailFolder.path))

        let undone = try await store.removeCorrection(of: id)
        XCTAssertEqual(undone?.classification.purpose, .promotion)
        XCTAssertEqual(undone?.isCorrected, false)
    }

    func testNotPhishingFollowsTheMessageNotAReusedMessageID() async throws {
        let store = try await open()
        let phish = { (body: String) in
            Self.eml(from: "CloudVault <no-reply@c1oudvault.example.com>", to: self.me, subject: "Your password expires",
                     id: "same-id", body: body)
        }
        try await store.save(MailAccount(id: account, displayName: "Corpus", address: me))
        let first = try await store.ingest(phish("Keep it: https://login.c1oudvault.example.com/a"), account: account).id
        let second = try await store.ingest(phish("Keep it now: https://login.c1oudvault.example.com/b"), account: account).id
        // Make c1oudvault a lookalike: the real one authenticates and you have written to someone there.
        try await store.ingest(Self.eml(from: "pat@cloudvault.example.com", to: me, subject: "Hi",
                                        headers: ["Authentication-Results: mx.example.net; dmarc=pass header.from=cloudvault.example.com"]),
                               account: account)
        try await store.ingest(Self.eml(from: me, to: "pat@cloudvault.example.com", subject: "Re: Hi"), account: account)
        let firstVerdict = try await store.verdict(of: first)
        XCTAssertEqual(firstVerdict?.home, .quarantine)

        let cleared = try await store.correct(first, risk: MailRisk.none)
        XCTAssertEqual(cleared?.classification.risk, MailRisk.none)
        XCTAssertEqual(cleared?.home, .focused, "a cleared security message goes back to Focused")
        XCTAssertEqual(cleared?.classification.urgency, .high, "with the urgency it would have had")
        let other = try await store.verdict(of: second)
        XCTAssertEqual(other?.classification.risk, .phishing, "another message with the same Message-ID keeps its warning")
    }

    func testARuleIsOnlyMadeWhenAskedAndCoversItsScope() async throws {
        let store = try await open()
        try await store.save(MailAccount(id: account, displayName: "Corpus", address: me))
        let list = ["List-ID: Weekly <weekly.news.example.org>", "List-Unsubscribe: <https://news.example.org/u>"]
        let a = try await store.ingest(Self.eml(from: "editor@news.example.org", to: me, subject: "Issue 1", headers: list), account: account).id
        let b = try await store.ingest(Self.eml(from: "editor@news.example.org", to: me, subject: "Issue 2", headers: list), account: account).id
        let otherAccount = MailAccountID("other")
        let c = try await store.ingest(Self.eml(from: "editor@news.example.org", to: me, subject: "Issue 3", headers: list), account: otherAccount).id

        try await store.correct(a, purpose: .conversation)
        let unchanged = try await store.verdict(of: b)
        XCTAssertEqual(unchanged?.classification.purpose, .subscription, "a correction never generalises")

        let rule = try await store.addRule(.list("<Weekly.News.example.org>"), purpose: .promotion, account: account)
        XCTAssertEqual(rule.scope, .list("weekly.news.example.org"))
        let ruled = try await store.verdict(of: b)
        XCTAssertEqual(ruled?.classification.purpose, .promotion)
        XCTAssertTrue(ruled?.classification.reasons.contains(.userRuleList) == true)
        let elsewhere = try await store.verdict(of: c)
        XCTAssertEqual(elsewhere?.classification.purpose, .subscription, "a rule stays in its account")
        let stillCorrected = try await store.verdict(of: a)
        XCTAssertEqual(stillCorrected?.classification.purpose, .conversation, "the message's own correction wins over the rule")

        try await store.removeRule(id: rule.id)
        let back = try await store.verdict(of: b)
        XCTAssertEqual(back?.classification.purpose, .subscription)
        let rules = try await store.classificationRules()
        XCTAssertEqual(rules, [])
    }

    // MARK: What history teaches

    func testAMessageMovedIntoJunkIsQuarantinedAndBackOutIsNot() async throws {
        let store = try await open()
        let id = try await store.ingest(Self.eml(from: "desk@prizes.example.net", to: me, subject: "Hello there"), account: account,
                                        remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 1)).id
        let inbox = try await store.verdict(of: id)
        XCTAssertEqual(inbox?.classification.risk, MailRisk.none)
        try await store.record(RemoteLocation(mailbox: "Junk", uidValidity: 1, uid: 9), for: id, account: account)
        try await store.forget(RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 1), account: account)
        let junk = try await store.verdict(of: id)
        XCTAssertEqual(junk?.classification.risk, .spam)
        XCTAssertEqual(junk?.home, .quarantine)
        try await store.record(RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 2), for: id, account: account)
        try await store.forget(RemoteLocation(mailbox: "Junk", uidValidity: 1, uid: 9), account: account)
        let back = try await store.verdict(of: id)
        XCTAssertEqual(back?.classification.risk, MailRisk.none)
    }

    func testWritingToSomeoneMakesTheirEarlierMailAConversation() async throws {
        let store = try await open()
        try await store.save(MailAccount(id: account, displayName: "Corpus", address: me))
        let list = ["List-ID: <club.lists.example.org>"]
        let id = try await store.ingest(Self.eml(from: "jo.lee@example.org", to: me, subject: "Saturday", headers: list), account: account).id
        let before = try await store.verdict(of: id)
        XCTAssertEqual(before?.classification.purpose, .subscription)
        try await store.ingest(Self.eml(from: me, to: "Jo <JO.LEE@example.org>", subject: "Re: Saturday"), account: account)
        let after = try await store.verdict(of: id)
        XCTAssertTrue(after?.classification.reasons.contains(.knownCorrespondent) == true)
    }

    func testALookalikeNeverBecomesTrustedAndEarlierLookalikesAreFlaggedOnceTheRealOneIs() async throws {
        let store = try await open()
        try await store.save(MailAccount(id: account, displayName: "Corpus", address: me))
        func authenticated(_ domain: String, _ date: String, _ n: Int) -> Data {
            Self.eml(from: "hello@\(domain)", to: me, subject: "News", date: date, id: "a\(n)-\(domain)",
                     headers: ["Authentication-Results: mx.example.net; spf=pass; dkim=pass; dmarc=pass header.from=\(domain)"])
        }
        // The lookalike arrives first, unflagged: nothing is trusted yet.
        let early = try await store.ingest(Self.eml(from: "no-reply@n0rdbank.example.com", to: me, subject: "Sign in to see your statement"),
                                           account: account).id
        let earlyVerdict = try await store.verdict(of: early)
        XCTAssertEqual(earlyVerdict?.classification.risk, MailRisk.none)
        // The real bank establishes itself: two authenticated messages a week apart.
        try await store.ingest(authenticated("nordbank.example.com", "Mon, 02 Nov 2026 10:00:00 +0000", 1), account: account)
        try await store.ingest(authenticated("nordbank.example.com", "Tue, 10 Nov 2026 10:00:00 +0000", 2), account: account)
        let trusted = try await store.trustedSenderDomains()
        XCTAssertEqual(trusted, ["nordbank.example.com"])
        let flagged = try await store.verdict(of: early)
        XCTAssertEqual(flagged?.classification.risk, .phishing, "reclassified once the real domain is trusted")
        // A lookalike that authenticates for itself never joins the trusted list.
        try await store.ingest(authenticated("n0rdbank.example.com", "Mon, 02 Nov 2026 10:00:00 +0000", 3), account: account)
        try await store.ingest(authenticated("n0rdbank.example.com", "Tue, 17 Nov 2026 10:00:00 +0000", 4), account: account)
        let still = try await store.trustedSenderDomains()
        XCTAssertEqual(still, ["nordbank.example.com"])
    }

    func testArrivalsAreNumberedOnceAsMailArrives() async throws {
        let store = try await open()
        let start = try await store.latestArrival()
        XCTAssertEqual(start, 0)
        let a = try await store.ingest(Self.eml(from: "jo.lee@example.org", to: me, subject: "One"), account: account).id
        let b = try await store.ingest(Self.eml(from: "jo.lee@example.org", to: me, subject: "Two"), account: account).id
        let arrivals = try await store.arrivals(after: 0)
        XCTAssertEqual(arrivals.map(\.id), [a, b])
        XCTAssertEqual(arrivals.map(\.home), [.focused, .focused])
        try await store.markVerdictsAsRuleSetForTesting("gkm-rules-1")
        try await store.classifyPending()
        let afterReclassify = try await store.arrivals(after: 0)
        XCTAssertEqual(afterReclassify.map(\.sequence), arrivals.map(\.sequence), "reclassifying never makes mail arrive again")
        let later = try await store.arrivals(after: arrivals[0].sequence)
        XCTAssertEqual(later.map(\.id), [b])
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, _ message: String) throws -> T {
    try XCTUnwrap(value, message)
}

extension MailStore {
    /// Makes the index look like one an older app left: version 3 without the classification
    /// tables; versions 1 and 2 simply marked older (they had no way forward but a rebuild).
    func downgradeIndexForTesting(to version: Int) throws {
        if version == 3 {
            try index.database.execute("DROP TABLE message_classes; DROP TABLE correspondents; DROP TABLE authenticated_domains;")
        }
        try index.database.setUserVersion(version)
    }

    func indexVersionForTesting() throws -> Int { try index.database.userVersion }

    func dropVerdictsForTesting() throws { try index.database.execute("DELETE FROM message_classes") }
    func markVerdictsAsRuleSetForTesting(_ version: String) throws {
        try index.database.prepare("UPDATE message_classes SET rule_version = ?").run([.text(version)])
    }
}
