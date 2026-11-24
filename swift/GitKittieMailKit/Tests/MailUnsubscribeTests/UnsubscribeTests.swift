import XCTest
import MailClassifier
import MailCore
import MailStore
@testable import MailUnsubscribe

/// GKM-020: what may be offered, and the one request that may be sent, proven against a real
/// local HTTP server that records every request. Nothing is contacted while mail is stored,
/// classified, listed or assessed; suspicious endpoints never; the approved request is one POST
/// with no cookies or credentials; redirects are not followed except a same-host 307/308.
@MainActor
final class UnsubscribeTests: XCTestCase {
    private var server: RecordingHTTPServer!

    override func setUp() async throws { server = try await RecordingHTTPServer.start() }
    override func tearDown() async throws { server.stop() }

    private var testPolicy: EndpointPolicy { EndpointPolicy(loopbackHTTPPorts: [Int(server.port)]) }

    private func headers(_ unsubscribe: String, oneClick: Bool = true, listID: String? = "Shop offers <offers.shop.example>") -> [String: String] {
        var headers = ["List-Unsubscribe": unsubscribe]
        if oneClick { headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click" }
        if let listID { headers["List-ID"] = listID }
        return headers
    }

    // MARK: What is offered

    func testALegitimateListGetsOneClickWithMailtoAsAnAlternative() {
        let assessment = UnsubscribeAssessor.assess(
            headers: headers("<https://unsubscribe.shop.example/u/abc>, <mailto:leave@shop.example?subject=stop&cc=boss@example.org>"),
            risk: .none, reasons: [.listID, .listUnsubscribe, .listUnsubscribePost], senderAddress: "news@shop.example")
        guard case .offer(let method, let alternatives) = assessment.outcome else { return XCTFail("\(assessment)") }
        XCTAssertEqual(method, .oneClick(URL(string: "https://unsubscribe.shop.example/u/abc")!))
        XCTAssertEqual(alternatives, [.mailto(address: "leave@shop.example", subject: "stop", body: "")], "cc is never taken from a mailto link")
        XCTAssertTrue(assessment.notes.isEmpty, "same organisation: nothing to point out")
    }

    func testSuspectedSpamIsNeverOfferedUnsubscribeButReportAsJunk() {
        let valid = headers("<https://unsubscribe.shop.example/u/abc>")
        for risk in [MailRisk.spam, .phishing, .suspicious] {
            let assessment = UnsubscribeAssessor.assess(headers: valid, risk: risk, reasons: [], senderAddress: "news@shop.example")
            XCTAssertEqual(assessment.outcome, .refused(.risky(risk)))
            XCTAssertTrue(assessment.suggestsReportingJunk)
            XCTAssertNil(assessment.method)
        }
        for reason in [ReasonCode.lookalikeSender, .displayNameSpoof, .authTrustedFail] {
            let assessment = UnsubscribeAssessor.assess(headers: valid, risk: .none, reasons: [reason], senderAddress: "news@shop.example")
            XCTAssertEqual(assessment.outcome, .refused(.doubtfulSender), "\(reason)")
            XCTAssertTrue(assessment.suggestsReportingJunk)
        }
    }

    func testWithoutListContextOrAHeaderNothingIsOffered() {
        XCTAssertEqual(UnsubscribeAssessor.assess(headers: [:], risk: .none, reasons: [], senderAddress: "a@shop.example").outcome,
                       .refused(.noHeader))
        let bare = headers("<https://unsubscribe.shop.example/u/abc>", oneClick: false, listID: nil)
        XCTAssertEqual(UnsubscribeAssessor.assess(headers: bare, risk: .none, reasons: [], senderAddress: "a@shop.example").outcome,
                       .refused(.noListContext))
    }

    func testSuspiciousEndpointsAreRefused() {
        let cases: [(String, EndpointProblem)] = [
            ("http://unsubscribe.shop.example/u", .notHTTPS),
            ("https://user:secret@unsubscribe.shop.example/u", .credentialsInURL),
            ("https://192.0.2.10/u", .ipAddressHost),
            ("https://2130706433/u", .ipAddressHost),
            ("https://[2001:db8::1]/u", .ipAddressHost),
            ("https://localhost/u", .localHost),
            ("https://router/u", .localHost),
            ("https://printer.local/u", .localHost),
            ("https://unsubscribe.shop.example:8443/u", .nonStandardPort),
            ("https://xn--shp-sna.example/u", .internationalisedHost),
            ("javascript:alert(1)", .unreadable),
        ]
        for (link, problem) in cases {
            XCTAssertEqual(EndpointPolicy.standard.problem(with: URL(string: link)!), problem, link)
            let assessment = UnsubscribeAssessor.assess(headers: headers("<\(link)>"), risk: .none, reasons: [], senderAddress: "news@shop.example")
            XCTAssertNil(assessment.method, link)
        }
        let lookalike = EndpointPolicy(trustedOrganisations: ["shop.example"])
        XCTAssertEqual(lookalike.problem(with: URL(string: "https://unsubscribe.sh0p.example/u")!), .lookalikeHost)
        // The test server's own address is refused by the policy the app uses.
        XCTAssertNotNil(EndpointPolicy.standard.problem(with: server.url("/u")))
    }

    func testAPlainHTTPSLinkWithoutOneClickIsManualAndAForeignHostIsPointedOut() {
        let manual = UnsubscribeAssessor.assess(headers: headers("<https://shop.example/preferences>", oneClick: false),
                                                risk: .none, reasons: [], senderAddress: "news@shop.example")
        XCTAssertEqual(manual.method, .manual(URL(string: "https://shop.example/preferences")!))

        let service = UnsubscribeAssessor.assess(headers: headers("<https://list.mailer.example/u/1>", listID: "<123.lists.mailer.example>"),
                                                 risk: .none, reasons: [], senderAddress: "news@shop.example")
        XCTAssertEqual(service.method, .oneClick(URL(string: "https://list.mailer.example/u/1")!))
        XCTAssertEqual(service.notes.count, 2, "the list and the endpoint belong to another organisation: both are said")
    }

    func testMailtoKeepsOnlyAddressSubjectAndBody() {
        XCTAssertEqual(UnsubscribeAssessor.parseMailto("mailto:Leave@Shop.example?subject=Stop%0D%0ABcc:%20x@evil.example&bcc=x@evil.example&body=please"),
                       .mailto(address: "leave@shop.example", subject: "StopBcc: x@evil.example", body: "please"))
        XCTAssertNil(UnsubscribeAssessor.parseMailto("mailto:leave@localhost"))
        XCTAssertNil(UnsubscribeAssessor.parseMailto("mailto:a@b.example,c@d.example"))
        XCTAssertNil(UnsubscribeAssessor.parseMailto("mailto:leave@192.0.2.1"))
    }

    // MARK: The request

    func testTheApprovedRequestIsOnePOSTWithNoCookiesOrCredentials() async throws {
        server.responses["/u/abc"] = .init(status: 202, headers: ["Set-Cookie": "tracker=1; Path=/"])
        let client = OneClickUnsubscriber(policy: testPolicy, timeout: 5)
        let first = await client.unsubscribe(server.url("/u/abc"))
        XCTAssertEqual(first, .accepted(status: 202))
        let second = await client.unsubscribe(server.url("/u/abc"))
        XCTAssertEqual(second, .accepted(status: 202))
        XCTAssertEqual(server.requests.count, 2)
        for request in server.requests {
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/u/abc")
            XCTAssertEqual(request.body, "List-Unsubscribe=One-Click")
            XCTAssertEqual(request.header("Content-Type"), "application/x-www-form-urlencoded")
            XCTAssertNil(request.header("Cookie"), "no cookie is ever sent, even one the server set")
            XCTAssertNil(request.header("Authorization"))
        }
    }

    func testARedirectElsewhereIsNotFollowed() async throws {
        server.responses["/u/1"] = .init(status: 302, headers: ["Location": "\(server.baseURL)/landing"])
        server.responses["/u/2"] = .init(status: 307, headers: ["Location": "http://localhost:\(server.port)/other-host"])
        server.responses["/u/3"] = .init(status: 307, headers: ["Location": "https://tracker.example/collect"])
        let client = OneClickUnsubscriber(policy: testPolicy, timeout: 5)
        let found = await client.unsubscribe(server.url("/u/1"))
        XCTAssertEqual(found, .redirectRefused(status: 302, host: "127.0.0.1"), "a 302 would turn the POST into a GET: never followed")
        let otherHost = await client.unsubscribe(server.url("/u/2"))
        XCTAssertEqual(otherHost, .redirectRefused(status: 307, host: "localhost"))
        let tracker = await client.unsubscribe(server.url("/u/3"))
        XCTAssertEqual(tracker, .redirectRefused(status: 307, host: "tracker.example"))
        XCTAssertEqual(server.requests.map(\.path), ["/u/1", "/u/2", "/u/3"], "nothing but the approved URLs was contacted")
    }

    func testASameHostTemporaryRedirectIsFollowedAtMostTwice() async throws {
        server.responses["/u/a"] = .init(status: 307, headers: ["Location": "/u/b"])
        server.responses["/u/b"] = .init(status: 200)
        let client = OneClickUnsubscriber(policy: testPolicy, timeout: 5)
        let followed = await client.unsubscribe(server.url("/u/a"))
        XCTAssertEqual(followed, .accepted(status: 200))
        XCTAssertEqual(server.requests.map(\.path), ["/u/a", "/u/b"])
        XCTAssertEqual(server.requests.last?.method, "POST")
        XCTAssertEqual(server.requests.last?.body, "List-Unsubscribe=One-Click")

        server.responses["/loop"] = .init(status: 308, headers: ["Location": "/loop"])
        let loop = await client.unsubscribe(server.url("/loop"))
        XCTAssertEqual(loop, .redirectRefused(status: 308, host: "127.0.0.1"))
        XCTAssertEqual(server.requests.filter { $0.path == "/loop" }.count, 1 + OneClickUnsubscriber.maxSameHostRedirects)
    }

    func testAnAuthenticationChallengeIsNeverAnswered() async throws {
        server.responses["/u/auth"] = .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"list\""])
        let client = OneClickUnsubscriber(policy: testPolicy, timeout: 5)
        let result = await client.unsubscribe(server.url("/u/auth"))
        switch result {
        case .rejected(401), .failed: break
        default: XCTFail("\(result)")
        }
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertNil(server.requests.first?.header("Authorization"))
    }

    func testTheAppsPolicyRefusesBeforeConnecting() async throws {
        let result = await OneClickUnsubscriber().unsubscribe(server.url("/u/abc"))
        XCTAssertEqual(result, .refused(.notHTTPS))
        XCTAssertEqual(server.connections, 0)
    }

    func testAFailedListIsReportedAsRejected() async throws {
        server.responses["/u/gone"] = .init(status: 404)
        let result = await OneClickUnsubscriber(policy: testPolicy, timeout: 5).unsubscribe(server.url("/u/gone"))
        XCTAssertEqual(result, .rejected(status: 404))
    }

    // MARK: Scanning

    /// Storing, classifying, listing senders, previewing rules and assessing unsubscribe read
    /// stored files only: the endpoint in the mail is never contacted.
    func testNothingIsContactedWhileMailIsScannedListedOrAssessed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unsub-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = MailAccountID("home")
        let store = try await MailStore.open(StoreLocations(mailFolder: root.appendingPathComponent("Mail"),
                                                            deviceFolder: root.appendingPathComponent("Support")))
        try await store.save(MailAccount(id: account, displayName: "Home", address: "sam.rivera@example.net"))
        let link = server.url("/u/scan")
        for n in 1...5 {
            let eml = """
                From: Shop <news@shop.example>\r
                To: sam.rivera@example.net\r
                Subject: 50% off sale \(n)\r
                Date: Mon, 0\(n) Nov 2026 10:00:00 +0000\r
                Message-ID: <scan-\(n)@shop.example>\r
                List-ID: <offers.shop.example>\r
                List-Unsubscribe: <\(link.absoluteString)>, <mailto:leave@shop.example>\r
                List-Unsubscribe-Post: List-Unsubscribe=One-Click\r
                Content-Type: text/html; charset=utf-8\r
                \r
                <p>Sale <img src="\(server.baseURL)/pixel.gif"> <a href="\(link.absoluteString)">unsubscribe</a></p>\r

                """
            try await store.ingest(Data(eml.utf8), account: account)
        }
        while try await store.classifyPending() > 0 {}
        let senders = try await store.senders(account: account)
        let list = try XCTUnwrap(senders.first { $0.scope.listID == "offers.shop.example" })
        _ = try await store.previewSenderRules([SenderRule(account: account, scope: list.scope, action: .mute)])
        let sourceValue = try await store.listHeaders(of: list.scope, account: account)
        let source = try XCTUnwrap(sourceValue)
        let assessment = UnsubscribeAssessor.assess(headers: source.headers, risk: source.verdict?.classification.risk ?? .none,
                                                    reasons: source.verdict?.classification.reasons ?? [],
                                                    senderAddress: source.verdict?.fromAddress, policy: testPolicy)
        XCTAssertEqual(assessment.method, .oneClick(link), "offered, with the test server allowed")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(server.connections, 0, "nothing was fetched while scanning, listing or assessing")

        // Only approving sends, and only the one request.
        _ = await OneClickUnsubscriber(policy: testPolicy, timeout: 5).unsubscribe(link)
        XCTAssertEqual(server.requests.map(\.path), ["/u/scan"])
    }

}
