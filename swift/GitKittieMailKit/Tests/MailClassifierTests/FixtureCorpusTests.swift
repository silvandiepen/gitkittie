import XCTest
import MailCore
import MailTestSupport

/// GKM-003: the corpus is complete, consistent, synthetic, and parses the way the
/// expectations say. These tests sit here rather than in their own target so the package
/// manifest stays untouched while other GKM cards add targets in parallel.
final class FixtureCorpusTests: XCTestCase {
    private var expectations: FixtureExpectations!
    private var urls: [URL]!

    override func setUpWithError() throws {
        expectations = try MailFixtures.expectations()
        urls = try MailFixtures.messageURLs()
    }

    func testEveryFixtureHasExactlyOneExpectation() throws {
        let files = urls.map(\.lastPathComponent)
        let expected = expectations.fixtures.map(\.file)
        XCTAssertEqual(Set(expected).count, expected.count, "an expectation is listed twice")
        XCTAssertEqual(Set(files), Set(expected), "every .eml needs an expectation and every expectation a file")
        XCTAssertGreaterThanOrEqual(files.count, 50)
        for fixture in expectations.fixtures {
            XCTAssertFalse(fixture.description.isEmpty, fixture.file)
            XCTAssertFalse(fixture.tags.isEmpty, fixture.file)
            XCTAssertEqual(fixture.parse.outcome == .ok, fixture.parse.warnings.isEmpty, "\(fixture.file): ok means no warnings")
            if fixture.parse.warnings.contains(where: \.isLimit) {
                XCTAssertEqual(fixture.parse.outcome, .limited, fixture.file)
            }
        }
    }

    func testCorpusCoversTheRequiredCases() {
        let fixtures = expectations.fixtures
        XCTAssertEqual(Set(fixtures.map(\.purpose)), Set(MailPurpose.allCases))
        XCTAssertEqual(Set(fixtures.map(\.risk)), Set(MailRisk.allCases))
        XCTAssertEqual(Set(fixtures.map(\.urgency)), Set(MailUrgency.allCases))
        XCTAssertEqual(Set(fixtures.map(\.parse.outcome)), Set(ParseOutcome.allCases))
        XCTAssertTrue(Set(fixtures.map(\.language)).isSuperset(of: ["en", "nl", "de", "ja", "el"]))
        let tags = Set(fixtures.flatMap(\.tags))
        let required = [
            "personal", "support", "receipt", "order", "invoice", "travel", "receipt-with-offer", "verification-code",
            "security-alert", "code-host", "newsletter", "digest", "list-id", "list-unsubscribe", "list-unsubscribe-post",
            "promotion", "reply-to-campaign", "display-name-spoof", "reply-to-mismatch", "lookalike-domain", "fake-invoice",
            "spam", "provider-verdict", "broken-boundary", "missing-closing-boundary", "mixed-charsets", "rfc2047",
            "huge-attachment", "nesting-bomb", "path-traversal", "missing-message-id", "duplicate-message-id", "unknown-charset",
            "bare-lf", "non-latin", "spoofed-trusted-sender", "link-text-mismatch", "dangerous-attachment",
        ]
        for tag in required { XCTAssertTrue(tags.contains(tag), "no fixture covers \(tag)") }
    }

    func testReaderMeetsTheParseExpectations() throws {
        for fixture in expectations.fixtures {
            let message = try read(fixture.file)
            XCTAssertEqual(message.outcome, fixture.parse.outcome, fixture.file)
            XCTAssertEqual(message.warnings, Set(fixture.parse.warnings), fixture.file)
            XCTAssertFalse(message.from.isEmpty, "\(fixture.file) has no readable From")
        }
    }

    func testOnlyReservedDomainsAppear() throws {
        let address = try NSRegularExpression(pattern: #"[A-Za-z0-9._%+/-]+@([A-Za-z0-9.-]+[A-Za-z0-9])"#)
        let url = try NSRegularExpression(pattern: #"https?://([A-Za-z0-9.-]+)"#)
        let reserved = try NSRegularExpression(pattern: #"(^|\.)example\.(com|org|net)$"#)
        for fileURL in urls {
            let data = try Data(contentsOf: fileURL)
            let message = ProvisionalMessageReader.read(data)
            // Raw bytes and the decoded text, so base64 bodies cannot hide a real address.
            let texts = [String(decoding: data, as: UTF8.self), message.headers.map(\.value).joined(separator: "\n"),
                         message.textBody ?? "", message.htmlBody ?? ""]
            for text in texts {
                let ns = text as NSString
                for pattern in [address, url] {
                    for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                        let host = ns.substring(with: match.range(at: 1)).lowercased()
                        let hit = reserved.firstMatch(in: host, range: NSRange(location: 0, length: (host as NSString).length))
                        XCTAssertNotNil(hit, "\(fileURL.lastPathComponent) mentions non-reserved host \(host)")
                    }
                }
            }
        }
    }

    func testMessageIDsRepeatOnlyWithinDeclaredDuplicateGroups() throws {
        var owners: [String: [FixtureExpectations.Fixture]] = [:]
        for fixture in expectations.fixtures {
            for id in try read(fixture.file).values("Message-ID") { owners[id, default: []].append(fixture) }
        }
        for (id, fixtures) in owners where fixtures.count > 1 {
            let groups = Set(fixtures.map(\.duplicateGroup))
            XCTAssertEqual(groups.count, 1, "\(id) is shared by fixtures from different groups")
            XCTAssertNotNil(groups.first ?? nil, "\(id) is shared but no duplicateGroup declares it")
        }
        for group in Set(expectations.fixtures.compactMap(\.duplicateGroup)) {
            XCTAssertTrue(owners.values.contains { $0.count > 1 && $0.allSatisfy { $0.duplicateGroup == group } }, group)
        }
    }

    func testAttachmentNamesAreReducedToOneSafeComponent() throws {
        for fixture in expectations.fixtures {
            for attachment in try read(fixture.file).attachments {
                XCTAssertFalse(attachment.safeFilename.contains("/"), fixture.file)
                XCTAssertFalse(attachment.safeFilename.contains("\\"), fixture.file)
                XCTAssertFalse(attachment.safeFilename.hasPrefix("."), fixture.file)
                XCTAssertFalse(attachment.safeFilename.isEmpty, fixture.file)
            }
        }
        let traversal = try read("mal-path-traversal-filenames.eml").attachments
        XCTAssertEqual(traversal.map(\.rawFilename), ["../../../../Library/LaunchAgents/com.example.agent.plist",
                                                       "../../.ssh/authorized_keys", #"C:\Windows\System32\drivers\etc\hosts"#])
        XCTAssertEqual(traversal.map(\.safeFilename), ["com.example.agent.plist", "authorized_keys", "hosts"])
        let huge = try read("mal-huge-attachment-placeholder.eml").attachments.first
        XCTAssertEqual(huge?.declaredSize, 3_221_225_472)
        XCTAssertLessThan(huge?.decodedByteCount ?? .max, 1024, "the placeholder must stay tiny in the repo")
    }

    func testDecodingSpotChecks() throws {
        XCTAssertEqual(try read("conv-personal-ja-meeting.eml").subject, "来週の打ち合わせについて")
        XCTAssertEqual(try read("conv-personal-ja-meeting.eml").from.first?.name, "田中 由紀")
        XCTAssertTrue(try read("conv-personal-ja-meeting.eml").textBody?.contains("打ち合わせ") == true)
        XCTAssertEqual(try read("conv-personal-de-thread.eml").subject, "Re: Ausflug nach Köln am Wochenende")
        XCTAssertTrue(try read("conv-personal-de-thread.eml").textBody?.contains("großartig") == true)
        XCTAssertEqual(try read("mal-encoded-words.eml").subject, "Café terras zaterdag?")
        XCTAssertEqual(try read("mal-encoded-words.eml").from.first?.name, "Jörg Müller")
        XCTAssertEqual(try read("mal-mixed-charsets.eml").subject, "Fotos vom Ausflug nach Köln 📷")
        XCTAssertEqual(try read("mal-mixed-charsets.eml").value("X-Mailer-Note"), "Grüße aus Köln")
        XCTAssertTrue(try read("conv-personal-el-unfamiliar.eml").textBody?.contains("Ελένη") == true)
        XCTAssertTrue(try read("mal-broken-boundary.eml").textBody?.contains("photos from Sunday") == true)
        XCTAssertEqual(try read("phish-display-name-spoof.eml").from.first?.address, "alerts@cv-alerts.example.net")
        XCTAssertEqual(try read("phish-display-name-spoof.eml").from.first?.name, "CloudVault Security <security@cloudvault.example.com>")
    }

    private func read(_ file: String) throws -> ProvisionalMessage {
        let url = try XCTUnwrap(MailFixtures.directory?.appendingPathComponent(file))
        return ProvisionalMessageReader.read(try Data(contentsOf: url))
    }
}
