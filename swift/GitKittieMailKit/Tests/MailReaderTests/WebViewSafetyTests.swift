import Network
import WebKit
import XCTest
import MailCore
@testable import MailHTML
import MailTestSupport
@testable import MailReader
@testable import MailReaderWeb
@testable import MailStore

/// ThreatModel §1, Phase 0 check: the hostile fixtures run no script and load nothing remote in
/// the real reader web view. Every `example.*` URL in a fixture is pointed at a listener on
/// 127.0.0.1, which counts every connection it gets. Control runs without the reader's
/// protections prove the fixtures do reach the listener and do run script when nothing stops
/// them, so a zero is a real zero.
@MainActor
final class WebViewSafetyTests: XCTestCase {
    private var server: CountingServer!
    private var ruleStoreFolder: URL!
    private var ruleLists: MailWebView.RuleLists!

    /// Whether a web content process has started in this test process yet.
    private static var webKitIsWarm = false

    override func setUp() async throws {
        try await Self.warmUpWebKit()
        server = try await CountingServer.start()
        ruleStoreFolder = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ruleStoreFolder, withIntermediateDirectories: true)
        ruleLists = try await MailWebView.ruleLists(store: try XCTUnwrap(WKContentRuleListStore(url: ruleStoreFolder)))
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: ruleStoreFolder)
    }

    // MARK: The reader

    func testHostileFixturesRunNoScriptAndLoadNothingInTheReader() async throws {
        for name in ["hostile-script-variants.eml", "hostile-css-exfiltration.eml", "hostile-tracking-pixels.eml",
                     "hostile-malformed-markup.eml", "lookalike-links.eml"] {
            server.reset()
            let html = try pointedAtServer(name)
            let view = MailWebView(ruleLists: ruleLists, allowRemoteImages: false)
            try await show(HTMLSanitizer.sanitize(html), in: view)
            XCTAssertEqual(server.connections, 0, "\(name): \(server.paths)")
            let marker = try await pwnedMarker(view)
            XCTAssertEqual(marker, "", "\(name): a script ran")
            XCTAssertEqual(view.url?.absoluteString, ReaderURLs.document, "\(name): the view navigated away")
        }
    }

    /// The network layers hold on their own: the raw, unsanitized HTML in the reader's web view
    /// (content rule list, JavaScript off, navigation guard, no CSP at all) still loads nothing.
    func testWithoutTheSanitizerTheWebViewStillLoadsNothingAndRunsNothing() async throws {
        for name in ["hostile-script-variants.eml", "hostile-css-exfiltration.eml", "hostile-tracking-pixels.eml"] {
            server.reset()
            let raw = try pointedAtServer(name)
            let view = MailWebView(ruleLists: ruleLists, allowRemoteImages: false)
            try await show(SanitizedHTML(document: raw, contentSecurityPolicy: "", links: [], remoteImages: 0, blockedRemoteReferences: 0,
                                         trackingPixels: 0, removedActiveContent: 0, hasForms: false, hasPasswordField: false, contentIDs: []), in: view)
            XCTAssertEqual(server.connections, 0, "\(name): \(server.paths)")
            let marker = try await pwnedMarker(view)
            XCTAssertEqual(marker, "", name)
        }
    }

    /// The content rule list alone, with JavaScript on: scripts run (that is what the other
    /// layers are for), but not one request leaves, not even from script.
    func testTheRuleListAloneBlocksEveryLoadEvenFromScript() async throws {
        server.reset()
        var raw = try pointedAtServer("hostile-script-variants.eml")
        raw += "<script>fetch('http://127.0.0.1:\(server.port)/fetch'); new Image().src='http://127.0.0.1:\(server.port)/image';</script>"
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(ruleLists.blockAll)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadHTMLString(raw, baseURL: nil)
        try await settle(view)
        XCTAssertEqual(server.connections, 0, "\(server.paths)")
        let marker = try await pwnedMarker(view)
        XCTAssertFalse(marker.isEmpty, "control: script did run in this configuration")
    }

    /// Control: with no protection at all, the fixtures reach the listener and run script.
    func testControlWithoutProtectionTheFixturesDoLoadAndRun() async throws {
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(server.port)/self-check")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "the listener answers")
        for name in ["hostile-script-variants.eml", "hostile-css-exfiltration.eml", "hostile-tracking-pixels.eml"] {
            server.reset()
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            view.loadHTMLString(try pointedAtServer(name), baseURL: nil)
            try await settle(view, extra: .seconds(2))
            XCTAssertGreaterThan(server.connections, 0, "\(name): the control made no request, so the zero above would prove nothing")
            if name == "hostile-script-variants.eml" {
                XCTAssertTrue(server.paths.contains("/meta"), "control: the meta refresh navigated the page: \(server.paths)")
            }
        }
        // The refresh replaces the page, so scripts are checked on the same HTML without it.
        let withoutRefresh = try pointedAtServer("hostile-script-variants.eml")
            .replacingOccurrences(of: #"<meta http-equiv="refresh"[^>]*>"#, with: "", options: .regularExpression)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.loadHTMLString(withoutRefresh, baseURL: nil)
        try await settle(view)
        let marker = try await pwnedMarker(view)
        XCTAssertFalse(marker.isEmpty, "control: scripts run without protection")
    }

    func testAllowedRemoteImagesLoadImagesButNeverTrackingPixelsOrCSS() async throws {
        server.reset()
        let html = try pointedAtServer("hostile-tracking-pixels.eml")
        let view = MailWebView(ruleLists: ruleLists, allowRemoteImages: true)
        try await show(HTMLSanitizer.sanitize(html, policy: .init(allowRemoteImages: true)), in: view, extra: .seconds(2))
        let paths = Set(server.paths)
        XCTAssertTrue(paths.contains("/hero.png"), "\(paths)")
        for pixel in ["/open?id=alex-4711", "/p.gif", "/w0.gif", "/protocol-relative.gif", "/input.png", "/poster.png", "/v.mp4", "/a.mp3",
                      "/x", "/ping", "/2x.png", "/source.webp"] {
            XCTAssertFalse(paths.contains(pixel), "\(pixel) was fetched")
        }

        server.reset()
        let css = MailWebView(ruleLists: ruleLists, allowRemoteImages: true)
        try await show(HTMLSanitizer.sanitize(try pointedAtServer("hostile-css-exfiltration.eml"), policy: .init(allowRemoteImages: true)), in: css)
        XCTAssertEqual(server.connections, 0, "\(server.paths)")
    }

    func testInlineImagesAreServedFromTheStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await MailStore.open(StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Device")))
        let id = try await store.ingest(try MailFixtures.hostileHTML("lookalike-links.eml"), account: MailAccountID("a")).id
        let content = ReaderContent.make(from: try await store.message(id))
        guard case .html(let html) = content.body else { return XCTFail("expected HTML") }
        var parts: [String: InlinePart] = [:]
        for (cid, reference) in content.inlineParts {
            parts[cid] = InlinePart(mediaType: reference.mediaType, data: try await store.attachmentData(reference))
        }
        let view = MailWebView(ruleLists: ruleLists, allowRemoteImages: false)
        try await show(html, in: view, parts: parts)
        let width = try await view.evaluateJavaScript("document.images[0].complete ? document.images[0].naturalWidth : -1", in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(width as? Int, 1, "the 1×1 logo came from the store")
        XCTAssertEqual(server.connections, 0)
    }

    #if os(macOS)
    func testClickingALinkReportsItAndNavigatesNowhere() async throws {
        let view = MailWebView(ruleLists: ruleLists, allowRemoteImages: false)
        var clicked: [Int] = []
        view.onLinkActivated = { clicked.append($0) }
        try await show(HTMLSanitizer.sanitize(#"<p><a href="http://127.0.0.1:\#(server.port)/clicked">Go</a></p>"#), in: view)
        // A real click, through AppKit's event path, on the link's position.
        let rect = try await view.evaluateJavaScript("JSON.stringify(document.links[0].getBoundingClientRect())", in: nil, contentWorld: .defaultClient)
        let frame = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(rect as? String).utf8)) as? [String: Double]
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = window.contentView!.bounds
        let point = CGPoint(x: (frame?["x"] ?? 0) + 4, y: 600 - (frame?["y"] ?? 0) - 6)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(clicked, [0])
        XCTAssertEqual(view.url?.absoluteString, ReaderURLs.document)
        XCTAssertEqual(server.connections, 0)
        window.contentView = nil
    }
    #else
    /// iOS has no public way to post a touch, so the link is activated by a click event from the
    /// app's own script world (content scripts stay off). WebKit treats it as a link activation,
    /// the same navigation a tap makes, and the guard must report it and navigate nowhere.
    func testActivatingALinkReportsItAndNavigatesNowhere() async throws {
        let view = MailWebView(ruleLists: ruleLists, allowRemoteImages: false)
        var clicked: [Int] = []
        view.onLinkActivated = { clicked.append($0) }
        try await show(HTMLSanitizer.sanitize(#"<p><a href="http://127.0.0.1:\#(server.port)/clicked">Go</a></p>"#), in: view)
        _ = try await view.evaluateJavaScript("document.links[0].click(); true", in: nil, contentWorld: .defaultClient)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(clicked, [0])
        XCTAssertEqual(view.url?.absoluteString, ReaderURLs.document)
        XCTAssertEqual(server.connections, 0)
    }
    #endif

    // MARK: Helpers

    /// The fixture's HTML with every `example.*` URL pointed at the listener.
    private func pointedAtServer(_ name: String) throws -> String {
        let eml = try MailFixtures.hostileHTML(name)
        let parsed = try MIMEMessageParser().parse(eml)
        let html = try XCTUnwrap(parsed.htmlBody, name)
        return html.replacingOccurrences(of: #"(?i)(https?:)?//[a-z0-9.-]*\.example\.(com|net|org)"#,
                                         with: "http://127.0.0.1:\(server.port)", options: .regularExpression)
    }

    private func show(_ html: SanitizedHTML, in view: MailWebView, parts: [String: InlinePart] = [:], extra: Duration = .milliseconds(1_200)) async throws {
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        var finished = false
        view.onContentHeight = { _ in finished = true }
        view.show(html, parts: parts)
        // Usually well under a second; the first web view on a cold simulator (CI) starts its
        // web content process first, which can take tens of seconds.
        let deadline = ContinuousClock.now + .seconds(90)
        while !finished, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        guard finished else { throw LoadTimedOut() }
        try await Task.sleep(for: extra)
    }

    private struct LoadTimedOut: Error, CustomStringConvertible {
        var description: String { "the document did not finish loading" }
    }

    /// Starts WebKit's processes once, with a plain web view, before any test measures anything.
    /// On a freshly booted simulator (CI) the first web content process takes over a minute to
    /// launch, and the first navigation made meanwhile can be lost; every later one is fast.
    private static func warmUpWebKit() async throws {
        guard !webKitIsWarm else { return }
        for _ in 0..<2 {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), configuration: configuration)
            view.loadHTMLString("<p id=warm>warm</p>", baseURL: nil)
            let deadline = ContinuousClock.now + .seconds(150)
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
                if !view.isLoading, view.url != nil {
                    webKitIsWarm = true
                    return
                }
            }
        }
        throw WarmUpFailed()
    }

    private struct WarmUpFailed: Error, CustomStringConvertible {
        var description: String { "WebKit did not load a plain page within 5 minutes" }
    }

    private func settle(_ view: WKWebView, extra: Duration = .milliseconds(1_200)) async throws {
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<200 where view.isLoading { try await Task.sleep(for: .milliseconds(25)) }
        try await Task.sleep(for: extra)
    }

    /// Every `data-pwned` value a script may have set, joined; empty when none ran.
    private func pwnedMarker(_ view: WKWebView) async throws -> String {
        let script = "Array.from(document.querySelectorAll('[data-pwned]')).map(e => e.getAttribute('data-pwned')).join(',')"
        return try await view.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) as? String ?? ""
    }
}

/// A TCP listener on 127.0.0.1 that counts connections and records request paths.
@MainActor
final class CountingServer {
    private let listener: NWListener
    private(set) var connections = 0
    private(set) var paths: [String] = []
    private(set) var port: UInt16 = 0
    private var isReady = false

    private init(listener: NWListener) {
        self.listener = listener
    }

    static func start() async throws -> CountingServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let server = CountingServer(listener: try NWListener(using: parameters))
        server.listener.newConnectionHandler = { [weak server] connection in
            MainActor.assumeIsolated { server?.accept(connection) }
        }
        server.listener.stateUpdateHandler = { [weak server] state in
            MainActor.assumeIsolated { if case .ready = state { server?.isReady = true } }
        }
        server.listener.start(queue: .main)
        for _ in 0..<500 where !server.isReady { try await Task.sleep(for: .milliseconds(10)) }
        server.port = server.listener.port?.rawValue ?? 0
        // Reading the port before the listener is ready gives 0, and then nothing can connect.
        guard server.isReady, server.port != 0 else { throw URLError(.cannotConnectToHost) }
        return server
    }

    func reset() {
        connections = 0
        paths = []
    }

    func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connections += 1
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            MainActor.assumeIsolated {
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let parts = request.split(separator: " ", maxSplits: 2)
                if parts.count >= 2 { self.paths.append(String(parts[1])) }
                let body = Data()
                let head = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
