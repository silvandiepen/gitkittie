import AppKit
import GitKanbanKit
import GitKittieKit
import SwiftUI
import WebKit
import XCTest

/// The Check in Browser web view (GITKITTIE-135), hosted in a window that is never shown: the
/// page lays out at the exact viewport of a size, also when it is drawn smaller to fit the
/// screen (the scaling spike: `pageZoom` keeps the layout width, and a click lands on the
/// element under it), the page sees the forced appearance and the size's user agent, and a
/// screenshot is at the full layout width.
@MainActor
final class CheckWebViewTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
    }

    /// A page that reports its viewport, colour scheme and user agent, with a 100 × 100 target
    /// at CSS (300, 600) that records where it was clicked.
    private static let page: URL = {
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;height:3000px}#t{position:absolute;left:300px;top:600px;width:100px;height:100px;background:red}</style>
        </head><body><div id="t"></div><script>
        document.body.dataset.hits = '';
        document.getElementById('t').addEventListener('click', e => { document.body.dataset.hits += 'target@' + e.clientX + ',' + e.clientY + ';' });
        document.addEventListener('click', e => { if (e.target.id !== 't') document.body.dataset.hits += 'page@' + e.clientX + ',' + e.clientY + ';' });
        </script></body></html>
        """
        return URL(string: "data:text/html;base64," + Data(html.utf8).base64EncodedString())!
    }()

    private func host(size: CheckSize, available: CGSize, appearance: CheckAppearance? = nil) -> (CheckWebController, CheckViewportLayout, NSWindow) {
        let controller = CheckWebController()
        let layout = CheckViewport.fit(size, in: available)
        let view = NSHostingView(rootView: CheckWebView(url: Self.page, layout: layout, appearance: appearance,
                                                        userAgent: CheckUserAgents.forSize(size), controller: controller)
            .frame(width: layout.shown.width, height: layout.shown.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: layout.shown), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        windows.append(window)
        return (controller, layout, window)
    }

    private func loaded(_ controller: CheckWebController, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if controller.webView != nil, !controller.isLoading,
               (await controller.evaluate("document.readyState")) as? String == "complete" { return }
        }
        XCTFail("the page did not load", file: file, line: line)
    }

    private func number(_ controller: CheckWebController, _ script: String) async -> Double {
        (await controller.evaluate(script) as? NSNumber)?.doubleValue ?? -1
    }

    func testThePageLaysOutAtTheExactViewport() async throws {
        let phone = try XCTUnwrap(CheckSize.presets.first { $0.id == "phone" })
        let (controller, layout, _) = host(size: phone, available: CGSize(width: 1600, height: 1000))
        XCTAssertFalse(layout.isScaled)
        await loaded(controller)
        let width = await number(controller, "innerWidth"), height = await number(controller, "innerHeight")
        XCTAssertEqual(width, 390)
        XCTAssertEqual(height, 844)
    }

    /// The spike: a viewport taller than the screen is drawn at 75 %, still laid out at 440 × 956,
    /// and a click lands where the element is drawn, reported in the page's own coordinates.
    func testAScaledViewportKeepsItsLayoutAndClicksLand() async throws {
        let large = try XCTUnwrap(CheckSize.presets.first { $0.id == "phone-large" })
        let (controller, layout, window) = host(size: large, available: CGSize(width: 1100, height: 717))
        XCTAssertEqual(layout.scale, 0.75, accuracy: 0.001)
        XCTAssertEqual(layout.shown, CGSize(width: 330, height: 717))
        await loaded(controller)
        let width = await number(controller, "innerWidth"), height = await number(controller, "innerHeight")
        XCTAssertEqual(width, 440, accuracy: 1, "laid out at the true width")
        XCTAssertEqual(height, 956, accuracy: 2, "laid out at the true height")
        let webView = try XCTUnwrap(controller.webView)

        // The middle of the target, CSS (350, 650), is drawn at (262.5, 487.5) from the top left.
        func click(css: CGPoint) {
            let inView = CGPoint(x: css.x * layout.scale, y: css.y * layout.scale)
            let flipped = CGPoint(x: inView.x, y: webView.bounds.height - inView.y)
            let point = webView.isFlipped ? webView.convert(inView, to: nil) : webView.convert(flipped, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                window.sendEvent(event)
            }
        }
        click(css: CGPoint(x: 350, y: 650))
        var hits = ""
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, hits.isEmpty {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            hits = (await controller.evaluate("document.body.dataset.hits") as? String) ?? ""
        }
        XCTAssertTrue(hits.hasPrefix("target@"), "the click lands on the element drawn under it: \(hits)")
        let coordinates = hits.dropFirst("target@".count).split(separator: ";")[0].split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(coordinates.count, 2)
        XCTAssertEqual(coordinates.first ?? 0, 350, accuracy: 2, "in the page's own coordinates")
        XCTAssertEqual(coordinates.last ?? 0, 650, accuracy: 2)

        // Beside the target: the page, not the target.
        click(css: CGPoint(x: 150, y: 300))
        let deadline2 = Date().addingTimeInterval(5)
        while Date() < deadline2, !hits.contains("page@") {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            hits = (await controller.evaluate("document.body.dataset.hits") as? String) ?? ""
        }
        XCTAssertTrue(hits.contains("page@"), "a click beside the target misses it: \(hits)")
    }

    func testTheAppearanceIsForcedOnThePage() async throws {
        let desktop = try XCTUnwrap(CheckSize.presets.first { $0.id == "laptop" })
        for (look, dark) in [(CheckAppearance.dark, true), (.light, false)] {
            let (controller, _, _) = host(size: desktop, available: CGSize(width: 1600, height: 1000), appearance: look)
            await loaded(controller)
            let matches = await controller.evaluate("matchMedia('(prefers-color-scheme: dark)').matches") as? Bool
            XCTAssertEqual(matches, dark, "\(look)")
        }
    }

    func testTheSizeAsksForItsUserAgent() async throws {
        let phone = try XCTUnwrap(CheckSize.presets.first { $0.id == "phone" })
        let (controller, _, _) = host(size: phone, available: CGSize(width: 1600, height: 1000))
        await loaded(controller)
        let agent = await controller.evaluate("navigator.userAgent") as? String
        XCTAssertTrue(agent?.contains("iPhone") == true, agent ?? "no user agent")
        let tablet = try XCTUnwrap(CheckSize.presets.first { $0.id == "tablet" })
        XCTAssertTrue(CheckUserAgents.forSize(tablet)?.contains("iPad") == true)
        XCTAssertTrue(CheckUserAgents.forSize(CheckSize.presets.first { $0.id == "desktop" }!)?.contains("Macintosh") == true)
    }

    func testAScreenshotIsAtTheFullLayoutWidth() async throws {
        let large = try XCTUnwrap(CheckSize.presets.first { $0.id == "phone-large" })
        let (controller, _, window) = host(size: large, available: CGSize(width: 1100, height: 717))
        await loaded(controller)
        let png = try XCTUnwrap(await controller.screenshotPNG())
        let image = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(Double(image.pixelsWide), 440 * Double(window.backingScaleFactor), accuracy: 2, "the full 440 px, at the screen's scale")
    }
}
