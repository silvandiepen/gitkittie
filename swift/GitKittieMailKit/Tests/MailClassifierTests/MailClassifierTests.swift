import XCTest
import MailCore
import MailClassifier
import MailTestSupport

final class MailClassifierTests: XCTestCase {
    func testFixturesAreBundled() throws {
        XCTAssertNotNil(MailFixtures.directory)
    }

    // MARK: - Corpus (GKM-007 verification)

    func testCorpusVerdicts() throws {
        let corpus = try Corpus.load()
        var rows: [(fixture: FixtureExpectations.Fixture, verdict: Classification)] = []
        for fixture in corpus.expectations.fixtures {
            rows.append((fixture, corpus.classifier.classify(try corpus.input(for: fixture))))
        }

        print(Report.confusion(title: "Purpose (rows = expected, columns = classified)", labels: MailPurpose.allCases.map(\.rawValue),
                               pairs: rows.map { ($0.fixture.purpose.rawValue, $0.verdict.purpose.rawValue) }))
        print(Report.precisionRecall(labels: MailPurpose.allCases.map(\.rawValue),
                                     pairs: rows.map { ($0.fixture.purpose.rawValue, $0.verdict.purpose.rawValue) }))
        print(Report.confusion(title: "Risk (rows = expected, columns = classified)", labels: MailRisk.allCases.map(\.rawValue),
                               pairs: rows.map { ($0.fixture.risk.rawValue, $0.verdict.risk.rawValue) }))
        print(Report.confusion(title: "Urgency (rows = expected, columns = classified)", labels: MailUrgency.allCases.map(\.rawValue),
                               pairs: rows.map { ($0.fixture.urgency.rawValue, $0.verdict.urgency.rawValue) }))
        for row in rows where row.fixture.purpose != row.verdict.purpose || row.fixture.risk != row.verdict.risk
            || row.fixture.urgency != row.verdict.urgency {
            print("MISMATCH \(row.fixture.file): expected \(row.fixture.purpose)/\(row.fixture.risk)/\(row.fixture.urgency), "
                  + "got \(row.verdict.purpose)/\(row.verdict.risk)/\(row.verdict.urgency) "
                  + "[\(row.verdict.reasons.map(\.rawValue).joined(separator: ", "))]")
        }

        for (fixture, verdict) in rows {
            // Acceptance: important mail is never classified as Promotion.
            if fixture.purpose.isImportant {
                XCTAssertNotEqual(verdict.purpose, .promotion, "\(fixture.file): important mail classified as promotion")
            }
            // False suppression costs more than a missed promotion: trustworthy important mail is never quarantined.
            if fixture.purpose.isImportant && fixture.risk == .none {
                XCTAssertFalse(verdict.risk.isQuarantined, "\(fixture.file): important mail quarantined as \(verdict.risk)")
            }
            // Acceptance: every verdict carries reason codes.
            XCTAssertFalse(verdict.reasons.isEmpty, "\(fixture.file): no reason codes")
            XCTAssertFalse(verdict.evidence.isEmpty, "\(fixture.file): no evidence")
            XCTAssertEqual(verdict.ruleSetVersion, MailClassifier.ruleSetVersion)
            XCTAssertTrue((0...1).contains(verdict.confidence), fixture.file)
            // Phishing look-alikes are flagged risky.
            if fixture.tags.contains("phishing") {
                XCTAssertTrue(verdict.risk == .phishing || verdict.risk == .suspicious, "\(fixture.file): phishing not flagged (\(verdict.risk))")
            }
        }

        // Acceptance (Classification.md): a retailer's receipt and offer are classified differently.
        let byFile = Dictionary(uniqueKeysWithValues: rows.map { ($0.fixture.file, $0.verdict) })
        XCTAssertEqual(byFile["txn-receipt-with-offer-en.eml"]?.purpose, .transaction)
        XCTAssertEqual(byFile["promo-sale-en.eml"]?.purpose, .promotion)
        XCTAssertEqual(byFile["phish-spoofed-trusted-sender.eml"]?.risk, .phishing)

        // Regression floor, not a target: the baseline measured 100% purpose accuracy on this corpus
        // when written; a drop below 90% means a rule change broke something.
        let correct = rows.filter { $0.fixture.purpose == $0.verdict.purpose }.count
        XCTAssertGreaterThanOrEqual(Double(correct) / Double(rows.count), 0.9)
    }

    func testClassificationIsDeterministic() throws {
        let corpus = try Corpus.load()
        for fixture in corpus.expectations.fixtures {
            let input = try corpus.input(for: fixture)
            XCTAssertEqual(corpus.classifier.classify(input), corpus.classifier.classify(input), fixture.file)
        }
    }

    // MARK: - Step 1 and 2 signals

    func testProviderPhishingVerdictWins() {
        let verdict = MailClassifier().classify(.init(from: MailAddress(address: "hello@friendly.example.org"), subject: "Hi",
                                                      textBody: "Hello there", provider: .init(verdict: .phishing)))
        XCTAssertEqual(verdict.risk, .phishing)
        XCTAssertTrue(verdict.reasons.contains(.providerPhishing))
    }

    func testAuthenticationResultsCountOnlyFromTrustedServers() {
        let header = { (id: String) in ClassificationInput.Header(name: "Authentication-Results", value: "\(id); spf=fail; dkim=none; dmarc=fail") }
        let classifier = MailClassifier(context: .init(trustedAuthServIDs: ["mx.example.net"]))
        let untrusted = classifier.classify(.init(from: MailAddress(address: "a@shop.example.com"), subject: "Your receipt",
                                                  headers: [header("mx.attacker.example.org")], textBody: "Total EUR 5"))
        XCTAssertEqual(untrusted.risk, .none)
        XCTAssertTrue(untrusted.reasons.contains(.authUntrustedIgnored))
        let trusted = classifier.classify(.init(from: MailAddress(address: "a@shop.example.com"), subject: "Your receipt",
                                                headers: [header("mx.example.net")], textBody: "Total EUR 5"))
        XCTAssertEqual(trusted.risk, .phishing)
        XCTAssertTrue(trusted.reasons.contains(.authTrustedFail))
    }

    func testBulkNoReplyReceiptStaysTransactional() {
        let verdict = MailClassifier().classify(.init(
            from: MailAddress(address: "no-reply@shop.example.com"), subject: "Your order confirmation",
            headers: [.init(name: "Precedence", value: "bulk"), .init(name: "List-Unsubscribe", value: "<https://shop.example.com/u>")],
            textBody: "Order 12. Total EUR 30.00. 20% off your next order!"))
        XCTAssertEqual(verdict.purpose, .transaction)
        XCTAssertTrue(verdict.reasons.contains(.transaction))
    }

    func testNothingToGoOnStaysUnknownAndVisible() {
        let verdict = MailClassifier().classify(.init(from: MailAddress(address: "no-reply@forms.example.org")))
        XCTAssertEqual(verdict.purpose, .unknown)
        XCTAssertEqual(verdict.risk, .none)
        XCTAssertNotEqual(verdict.urgency, .low)
        XCTAssertEqual(verdict.reasons.last, .insufficientEvidence)
    }

    // MARK: - Step 3: overrides and scoped rules

    private let newsletter = ClassificationInput(
        messageID: "<n-1@news.example.org>", from: MailAddress(name: "News", address: "editor@news.example.org"),
        subject: "Issue 4", headers: [.init(name: "List-ID", value: "Weekly <weekly.news.example.org>")], textBody: "This week")

    func testOverrideWinsOverRulesForThatMessageOnly() {
        let classifier = MailClassifier(context: .init(
            overrides: [MessageOverride(messageID: "<n-1@news.example.org>", purpose: .conversation)],
            rules: [ScopedRule(id: "r1", scope: .listID("weekly.news.example.org"), purpose: .promotion)]))
        let verdict = classifier.classify(newsletter)
        XCTAssertEqual(verdict.purpose, .conversation)
        XCTAssertEqual(verdict.confidence, 1)
        XCTAssertTrue(verdict.reasons.contains(.userOverride))
        var other = newsletter
        other.messageID = "<n-2@news.example.org>"
        XCTAssertEqual(classifier.classify(other).purpose, .promotion, "an override never generalises")
    }

    func testMoreSpecificScopeWinsThenOrder() {
        let rules = [
            ScopedRule(id: "domain", scope: .senderDomain("example.org"), purpose: .notification),
            ScopedRule(id: "sender", scope: .senderAddress("EDITOR@news.example.org"), purpose: .promotion),
            ScopedRule(id: "list-b", scope: .listID("<weekly.news.example.org>"), purpose: .transaction, order: 2),
            ScopedRule(id: "list-a", scope: .listID("weekly.news.example.org"), purpose: .conversation, order: 1),
            ScopedRule(id: "list-0", scope: .listID("weekly.news.example.org"), purpose: .security, order: 0, isEnabled: false),
        ]
        let verdict = MailClassifier(context: .init(rules: rules)).classify(newsletter)
        XCTAssertEqual(verdict.purpose, .conversation)
        XCTAssertTrue(verdict.reasons.contains(.userRuleList))
        XCTAssertEqual(verdict.evidence.last?.detail, "list-a")

        var noList = newsletter
        noList.headers = []
        XCTAssertEqual(MailClassifier(context: .init(rules: rules)).classify(noList).purpose, .promotion)
        noList.from = MailAddress(address: "someone@sub.news.example.org")
        XCTAssertEqual(MailClassifier(context: .init(rules: rules)).classify(noList).purpose, .notification)
    }

    func testRulesMatchTheAddressNotTheDisplayNameAndNeverLowerRisk() {
        let context = ClassificationContext(trustedSenderDomains: ["cloudvault.example.com"],
                                            rules: [ScopedRule(id: "cv", scope: .senderDomain("cloudvault.example.com"),
                                                               purpose: .notification, urgency: .low)])
        let spoof = ClassificationInput(from: MailAddress(name: "security@cloudvault.example.com", address: "x@c1oudvault.example.com"),
                                        subject: "Verify your account", textBody: "Sign in now")
        let verdict = MailClassifier(context: context).classify(spoof)
        XCTAssertFalse(verdict.reasons.contains(.userRuleDomain), "display name must not match a sender rule")
        XCTAssertEqual(verdict.risk, .phishing)

        let genuineAddressSpoofed = ClassificationInput(
            from: MailAddress(address: "security@cloudvault.example.com"), subject: "Verify your account",
            textBody: "Sign in at https://c1oudvault.example.com/login")
        let ruled = MailClassifier(context: context).classify(genuineAddressSpoofed)
        XCTAssertEqual(ruled.purpose, .notification, "the rule sets purpose")
        XCTAssertEqual(ruled.risk, .phishing, "but cannot clear the risk")
        XCTAssertEqual(ruled.urgency, .low)
    }
}

// MARK: - Corpus adapter and report

private struct Corpus {
    let expectations: FixtureExpectations
    let classifier: MailClassifier

    static func load() throws -> Corpus {
        let expectations = try MailFixtures.expectations()
        let c = expectations.context
        let context = ClassificationContext(accountAddresses: Set(c.accountAddresses), trustedAuthServIDs: Set(c.trustedAuthServIDs),
                                            knownCorrespondents: Set(c.knownCorrespondents),
                                            trustedSenderDomains: Set(c.trustedSenderDomains))
        return Corpus(expectations: expectations, classifier: MailClassifier(context: context))
    }

    /// Provisional adapter: ProvisionalMessage (MailTestSupport) to the classifier's view model.
    func input(for fixture: FixtureExpectations.Fixture) throws -> ClassificationInput {
        let url = try XCTUnwrap(MailFixtures.directory?.appendingPathComponent(fixture.file))
        let message = ProvisionalMessageReader.read(try Data(contentsOf: url))
        var flags: Set<StructureFlag> = []
        if message.warnings.contains(.nestingLimitExceeded) { flags.insert(.nestingLimitExceeded) }
        if message.warnings.contains(.unsafeAttachmentFilename) { flags.insert(.unsafeAttachmentFilename) }
        return ClassificationInput(
            messageID: message.messageID, from: message.from.first, replyTo: message.replyTo, subject: message.subject,
            headers: message.headers.map { .init(name: $0.name, value: $0.value) },
            textBody: message.textBody ?? "", htmlBody: message.htmlBody,
            attachmentFilenames: message.attachments.map(\.safeFilename), structureFlags: flags,
            provider: fixture.providerVerdict.flatMap(ProviderSignals.Verdict.init(rawValue:)).map { ProviderSignals(verdict: $0) })
    }
}

private enum Report {
    static func confusion(title: String, labels: [String], pairs: [(String, String)]) -> String {
        let width = max(labels.map(\.count).max() ?? 0, 6) + 1
        func pad(_ s: String) -> String { s.padding(toLength: width, withPad: " ", startingAt: 0) }
        var out = "\n\(title)\n" + pad("") + labels.map { pad(String($0.prefix(width - 1))) }.joined() + "\n"
        for expected in labels {
            out += pad(expected)
            for actual in labels {
                let n = pairs.filter { $0.0 == expected && $0.1 == actual }.count
                out += pad(n == 0 ? "." : String(n))
            }
            out += "\n"
        }
        return out
    }

    static func precisionRecall(labels: [String], pairs: [(String, String)]) -> String {
        var out = "\nPer purpose: precision / recall (support)\n"
        for label in labels {
            let tp = pairs.filter { $0.0 == label && $0.1 == label }.count
            let predicted = pairs.filter { $0.1 == label }.count
            let actual = pairs.filter { $0.0 == label }.count
            let precision = predicted == 0 ? "n/a" : String(format: "%.2f", Double(tp) / Double(predicted))
            let recall = actual == 0 ? "n/a" : String(format: "%.2f", Double(tp) / Double(actual))
            out += "  \(label.padding(toLength: 13, withPad: " ", startingAt: 0)) \(precision) / \(recall) (\(actual))\n"
        }
        let correct = pairs.filter { $0.0 == $0.1 }.count
        out += String(format: "  accuracy      %.2f (%d/%d)\n", Double(correct) / Double(pairs.count), correct, pairs.count)
        return out
    }
}
