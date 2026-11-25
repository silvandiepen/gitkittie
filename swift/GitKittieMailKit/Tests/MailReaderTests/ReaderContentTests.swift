import XCTest
import MailClassifier
import MailCore
import MailHTML
import MailTestSupport
@testable import MailReader
@testable import MailStore

/// GKM-012: links, senders and what the reader lists, worked out with no network.
final class ReaderContentTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("reader-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func stored(_ eml: Data) async throws -> StoredMessage {
        let store = try await MailStore.open(locations)
        let id = try await store.ingest(eml, account: MailAccountID("acct"))
        return try await store.message(id.id)
    }

    func testTheLookalikeFixtureWarnsAboutEveryDeceptiveLink() async throws {
        let message = try await stored(try MailFixtures.hostileHTML("lookalike-links.eml"))
        let content = ReaderContent.make(from: message)
        let byText = Dictionary(uniqueKeysWithValues: content.links.map { ($0.link.text, $0) })

        let shownOther = try XCTUnwrap(byText["https://www.cloudvault.example.com/account"])
        XCTAssertEqual(shownOther.host, "cloudvau1t.example.net")
        XCTAssertEqual(shownOther.registrableDomain, "cloudvau1t.example.net")
        XCTAssertTrue(shownOther.warnings.contains(.textShowsOtherDomain(shown: "www.cloudvault.example.com")), "\(shownOther.warnings)")
        XCTAssertFalse(shownOther.warnings.contains { if case .lookalike = $0 { return true }; return false },
                       "it is the sender's own domain, so not a lookalike of it")

        let userInfo = try XCTUnwrap(byText["Verify your account"])
        XCTAssertEqual(userInfo.host, "login.example.net")
        XCTAssertTrue(userInfo.warnings.contains(.userInfoInURL))

        let idn = try XCTUnwrap(byText["clоudvault.example.com"])
        XCTAssertEqual(idn.host, "xn--cludvault-12h.example.com")
        XCTAssertTrue(idn.warnings.contains(.mixedScripts), "\(idn.warnings)")
        XCTAssertTrue(idn.displayDestination.contains("xn--cludvault-12h"))

        let ip = try XCTUnwrap(byText["Upgrade storage"])
        XCTAssertTrue(ip.warnings.contains(.ipAddressHost))
        XCTAssertTrue(ip.warnings.contains(.unencrypted))

        XCTAssertTrue(try XCTUnwrap(byText["Write to support"]).warnings.isEmpty)
        XCTAssertEqual(try XCTUnwrap(byText["Write to support"]).openURL?.absoluteString, "mailto:support@cloudvault.example.com")
        for blocked in ["Local file", "Data URL", "Open the app"] {
            let link = try XCTUnwrap(byText[blocked])
            XCTAssertNil(link.openURL, blocked)
            XCTAssertTrue(link.warnings.contains { if case .blockedScheme = $0 { return true }; return false }, blocked)
        }
        // The real help-centre link resembles the (fake) sender's domain: flagged too, neutrally worded.
        XCTAssertTrue(try XCTUnwrap(byText["Help centre"]).warnings.contains(.lookalike(of: "cloudvau1t.example.net")))
        XCTAssertEqual(content.suspiciousLinkCount, 8)

        // The sender: display name names another domain; replies go elsewhere.
        XCTAssertEqual(content.sender.address, "alerts@cloudvau1t.example.net")
        XCTAssertEqual(content.sender.warnings, [.nameMentionsOtherDomain("cloudvault.example.com"), .replyToDiffers("billing@payments.example.org")])

        // The inline logo is shown in the HTML, not listed; the PDF is listed.
        XCTAssertEqual(content.attachments.map(\.fileName), ["storage-report.pdf"])
        XCTAssertEqual(Array(content.inlineParts.keys), ["logo@cloudvault"])
        XCTAssertNotNil(content.plainAlternative)
        XCTAssertEqual(ReaderContent.make(from: message, preferPlainText: true).body.isPlain, true)
    }

    func testALookalikeOfTheSendersDomainIsNamed() {
        let link = HTMLLink(index: 0, href: "https://nordbank-kundenservice.example.org/login", text: "Log in", isAllowedScheme: true)
        let assessment = LinkInspector.assess(link, senderAddress: "service@nordbank.example.org")
        XCTAssertEqual(assessment.warnings, [.lookalike(of: "nordbank.example.org")])
        let same = LinkInspector.assess(HTMLLink(index: 1, href: "https://www.nordbank.example.org/x", text: "nordbank.example.org", isAllowedScheme: true),
                                        senderAddress: "service@nordbank.example.org")
        XCTAssertEqual(same.warnings, [])
    }

    /// GKM-012, answered by Sil: warn always, worded neutrally. The warning does not depend on
    /// whether the sender is known or trusted, and it is there when the sender itself is the
    /// fake one; the wording says what differs, never "phishing" or "scam".
    func testTheLookalikeWarningIsAlwaysGivenAndWordedNeutrally() {
        let link = HTMLLink(index: 0, href: "https://c1oudvault.example/login", text: "Sign in", isAllowedScheme: true)
        // A sender never seen before, from the real domain.
        let unknown = LinkInspector.assess(link, senderAddress: "news@cloudvault.example")
        XCTAssertEqual(unknown.warnings, [.lookalike(of: "cloudvault.example")])
        // A sender that is itself a lookalike, whose name names another domain: still warned.
        let fakeSender = SenderAssessment.assess(from: [MailAddress(name: "CloudVault (cloudvault.example)", address: "alerts@c1oudvault.example")],
                                                 replyTo: [])
        XCTAssertFalse(fakeSender.warnings.isEmpty)
        let fromFake = LinkInspector.assess(HTMLLink(index: 1, href: "https://cloudvault.example/login", text: "Sign in", isAllowedScheme: true),
                                            senderAddress: "alerts@c1oudvault.example")
        XCTAssertEqual(fromFake.warnings, [.lookalike(of: "c1oudvault.example")], "either one may be the fake")
        for warning in unknown.warnings + fromFake.warnings {
            let text = warning.message.lowercased()
            XCTAssertFalse(["phish", "scam", "fraud", "danger", "malicious"].contains { text.contains($0) }, text)
            XCTAssertTrue(text.contains("looks like"), text)
        }
    }

    func testObfuscatedSchemesAreBlocked() {
        for href in ["java\tscript:alert(1)", " JAVASCRIPT:alert(1)", "vbscript:x", "data:text/html,x", "file:///etc/hosts", "app-scheme://x"] {
            let assessment = LinkInspector.assess(HTMLLink(index: 0, href: href, text: "x", isAllowedScheme: false), senderAddress: nil)
            XCTAssertNil(assessment.openURL, href)
        }
    }

    func testSenderNameCarryingAnotherAddress() {
        let spoof = SenderAssessment.assess(from: [MailAddress(name: "service@paypal.example.com", address: "x@evil.example.net")], replyTo: [])
        XCTAssertEqual(spoof.warnings, [.nameContainsOtherAddress("service@paypal.example.com")])
        let honest = SenderAssessment.assess(from: [MailAddress(name: "Ada Example", address: "ada@example.com")],
                                             replyTo: [MailAddress(address: "ada.private@example.com")])
        XCTAssertEqual(honest.warnings, [])
        XCTAssertEqual(SenderAssessment.assess(from: [], replyTo: []).warnings, [.noSender])
    }

    func testPunycode() {
        XCTAssertEqual(Punycode.asciiHost("bücher.example.com"), "xn--bcher-kva.example.com")
        XCTAssertEqual(Punycode.unicodeHost("xn--bcher-kva.example.com"), "bücher.example.com")
        XCTAssertEqual(Punycode.asciiHost("例え.example.org"), "xn--r8jz45g.example.org")
        XCTAssertEqual(Punycode.unicodeHost("xn--r8jz45g.example.org"), "例え.example.org")
        XCTAssertEqual(Punycode.unicodeHost("xn--!!.example.org"), "xn--!!.example.org", "undecodable stays as written")
    }

    func testRemoteImagePreferencePersists() async throws {
        let preferences = RemoteContentPreferences(deviceFolder: locations.deviceFolder)
        let before = await preferences.allowsRemoteImages(from: "News@Example.com")
        XCTAssertFalse(before)
        try await preferences.setAllowsRemoteImages(true, from: "News@Example.com")
        let reopened = RemoteContentPreferences(deviceFolder: locations.deviceFolder)
        let after = await reopened.allowsRemoteImages(from: "news@example.com")
        XCTAssertTrue(after)
        try await reopened.setAllowsRemoteImages(false, from: "news@example.com")
        let senders = await RemoteContentPreferences(deviceFolder: locations.deviceFolder).senders
        XCTAssertEqual(senders, [])
    }
}

extension ReaderContent.Body {
    var isPlain: Bool { if case .plain = self { return true }; return false }
}
