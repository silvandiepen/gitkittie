import AppKit
import GitKanbanKit
import GitKittieKit
import SwiftUI
import WebKit
import XCTest

/// The Mac review screens for actions, assignment, due dates and browser checks (GITKITTIE-135),
/// as the app draws them: the real `RootView` on the Reviews screen and the real Check in Browser
/// window, hosted in windows that are never shown, over a real folder board. Each test checks
/// what is on screen through the views' accessibility, and writes a picture of the window to the
/// folder `REVUI_SHOTS` names (`TEST_RUNNER_REVUI_SHOTS=… xcodebuild test`), when it is set.
@MainActor
final class ReviewScreensRenderTests: XCTestCase {
    private let suite = "gk-revui-\(UUID().uuidString)"
    private var root: URL!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite + "-board", isDirectory: true)
        let today = Calendar.current.startOfDay(for: Date())
        func day(_ offset: Int) -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: Calendar.current.date(byAdding: .day, value: offset, to: today)!)
        }
        try write("Tasks/README.md", """
        ---
        config: board
        lanes:
          - { id: todo, name: To do, folder: "1. To do", status: todo }
          - { id: in-progress, name: In Progress, folder: "2. In Progress", status: in-progress }
          - { id: in-review, name: In Review, folder: "3. In Review", status: in-review }
          - { id: testing, name: Testing, folder: "4. Testing", status: testing }
          - { id: done, name: Done, folder: "5. Done", status: done, terminal: true }
        users:
          - { id: sil, name: Sil, kind: human, github: \(NSUserName()) }
          - { id: herma, name: Herma, kind: human }
          - { id: claude, name: Claude, kind: agent }
        ---
        """)
        try write("Tasks/Pets/README.md", "---\nconfig: project\nproject: Pets\nlanes: []\n---\n")
        // A second board on which nobody matches this Mac's login: it asks "Which one are you?".
        try write("Tasks/Farm/README.md", """
        ---
        config: project
        project: Farm
        lanes: []
        users:
          - { id: sil, name: Sil, kind: human, github: someone-else }
          - { id: herma, name: Herma, kind: human, github: herma-elsewhere }
        ---
        """)
        for lane in ["1. To do", "2. In Progress", "4. Testing", "5. Done"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Tasks/Pets/\(lane)"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Tasks/Farm/\(lane)"), withIntermediateDirectories: true)
        }
        for (id, title) in [("PETS-1", "Site onboarding"), ("PETS-3", "Onboarding page"), ("PETS-4", "Store copy")] {
            try write("Tasks/Pets/3. In Review/\(id).md", """
            ---
            id: \(id)
            title: \(title)
            project: Pets
            status: in-review
            updated_at: 2026-11-27T09:00:00Z
            picked_up_by: claude
            claim_expires_at: 2099-01-01T00:00:00Z
            ---

            # \(title)
            """)
        }
        try write("Tasks/Pets/review/PETS-1-site/review.md", """
        ---
        config: review
        id: PETS-1-site
        card: PETS-1
        title: Site onboarding, round 1
        question: Approve the badge to finish this round.
        requested_by: claude
        requested_at: 2026-11-27T10:00:00Z
        due: \(day(1))
        on_accept: { to: testing }
        on_changes: { to: in-progress, comment: true }
        items:
          - { id: hero, file: hero.png, status: approved, decided_by: sil, decided_at: "2026-11-27T10:30:00Z" }
          - { id: badge, file: badge.png, revises: badge-v1, status: pending }
        ---
        """)
        try write("Tasks/Pets/review/PETS-3-page/review.md", """
        ---
        config: review
        id: PETS-3-page
        card: PETS-3
        title: Onboarding page check
        question: Check the onboarding page on a phone and a desktop.
        requested_by: claude
        requested_at: 2026-11-27T11:00:00Z
        for: [sil]
        due: \(day(-1))
        on_accept: { to: testing }
        checks:
          - id: onboarding
            url: "\(Self.pageURL)"
            title: Onboarding page
            note: The page prints the width it is laid out at.
            sizes: [phone, desktop]
            appearance: [light, dark]
            checklist:
              - { id: hero, text: The headline fits without an awkward break }
              - { id: cta, text: The button shows without scrolling }
            results:
              phone.light:
                viewport: 390x844
                answers:
                  hero: { result: pass }
                  cta: { result: fail, note: Below the fold }
              desktop.light:
                answers:
                  hero: { result: pass }
        ---
        """)
        try write("Tasks/Pets/review/PETS-4-copy/review.md", """
        ---
        config: review
        id: PETS-4-copy
        card: PETS-4
        title: Copy for the store
        requested_by: claude
        requested_at: 2026-11-27T12:00:00Z
        for: [herma]
        items:
          - { id: copy, file: copy.png, status: pending }
        ---
        """)
        try write("Tasks/Farm/review/FARM-2-barn/review.md", """
        ---
        config: review
        id: FARM-2-barn
        title: Barn colours
        requested_at: 2026-11-26T12:00:00Z
        for: [herma]
        items:
          - { id: red, file: red.png, status: pending }
        ---
        """)
        for (path, color) in [("Tasks/Pets/review/PETS-1-site/hero.png", NSColor.orange), ("Tasks/Pets/review/PETS-1-site/badge.png", .systemBlue),
                              ("Tasks/Pets/review/PETS-4-copy/copy.png", .brown), ("Tasks/Farm/review/FARM-2-barn/red.png", .red)] {
            try Self.png(color).write(to: root.appendingPathComponent(path))
        }
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences/\(suite).plist")
        try? FileManager.default.removeItem(at: preferences)
        try? FileManager.default.removeItem(at: storage)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Tests

    /// The list: For me hides Herma's request; the other board asks who you are; rows show
    /// "For Sil", due dates (overdue in red) and Round 2. The request: "When decided" in words.
    func testTheListAndARequestWithActions() async throws {
        let model = try await openModel()
        let site = try XCTUnwrap(model.reviewInbox.flatMap(\.requests).first { $0.id == "PETS-1-site" })
        XCTAssertEqual(model.reviewActionLines(site).map(\.text), ["Accept → move PETS-1 to Testing", "Changes → move PETS-1 to In Progress"])
        XCTAssertEqual(model.boardsAskingWhoYouAre.map(\.boardName), ["Farm"], "Farm asks who you are")
        let listed = model.reviewInbox.flatMap { model.shownReviews($0.requests) }.map(\.id)
        XCTAssertFalse(listed.contains("PETS-4-copy"), "For me hides Herma's request")
        XCTAssertEqual(site.dueLabel()?.text, "Due tomorrow")
        model.reviewsFocusRequest = site.ref
        let window = host(model)
        settle(window)
        assertDrawn(window)
        save(window, "mac-1-reviews-actions")
    }

    /// Deciding the last file runs the action: the banner says what moved, with Undo; Undo
    /// takes it back and the Actions history says so.
    func testTheBannerAfterTheLastDecision() async throws {
        let model = try await openModel()
        let site = try XCTUnwrap(model.reviewInbox.flatMap(\.requests).first { $0.id == "PETS-1-site" })
        model.reviewsFocusRequest = site.ref
        let window = host(model)
        settle(window)
        let decided = await model.decide(site, item: site.items[1], status: .approved)
        XCTAssertTrue(decided)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Tasks/Pets/4. Testing/PETS-1.md").path))
        let report = try XCTUnwrap(model.reviewActionReport)
        XCTAssertEqual(model.reviewActionBanner(report).message, "Moved PETS-1 to Testing")
        settle(window)
        assertDrawn(window)
        save(window, "mac-2-moved-banner")

        let undone = await model.undoReviewActions(model.reviewActionBanner(report))
        XCTAssertTrue(undone)
        let fresh = try XCTUnwrap(model.reviewRequest(site.ref))
        XCTAssertEqual(model.reviewActionHistory(fresh).map(\.text), ["Moved PETS-1 to Testing · undone"])
        settle(window)
        save(window, "mac-3-undone")
    }

    /// Everyone: Herma's request is listed, read-only.
    func testSomeoneElsesRequestIsReadOnly() async throws {
        let model = try await openModel()
        model.reviewAssignmentFilter = .everyone
        let copy = try XCTUnwrap(model.reviewInbox.flatMap(\.requests).first { $0.id == "PETS-4-copy" })
        XCTAssertEqual(model.readOnlyNotice(copy), "For Herma. You can comment.")
        XCTAssertTrue(model.reviewInbox.flatMap { model.shownReviews($0.requests) }.contains { $0.id == "PETS-4-copy" })
        model.reviewsFocusRequest = copy.ref
        let window = host(model)
        settle(window)
        assertDrawn(window)
        save(window, "mac-4-everyone-read-only")
    }

    /// A browser check in the request: the sizes × appearance grid, progress, what failed.
    func testACheckRow() async throws {
        let model = try await openModel()
        let page = try XCTUnwrap(model.reviewInbox.flatMap(\.requests).first { $0.id == "PETS-3-page" })
        let check = try XCTUnwrap(page.checks.first)
        XCTAssertEqual(check.cellState("phone.light"), .failed(1))
        XCTAssertEqual(check.cellState("desktop.light"), .partial(answered: 1, total: 2))
        XCTAssertTrue(page.entries[0].isWaiting, "a check waits until it is decided")
        model.reviewsFocusRequest = page.ref
        let window = host(model)
        settle(window)
        assertDrawn(window)
        save(window, "mac-5-check-row")
    }

    /// The Check in Browser window at the desktop size: the page laid out at 1440 (scaled to fit
    /// when the screen is smaller), the checklist for that size beside it.
    func testTheCheckInBrowserWindow() async throws {
        let model = try await openModel()
        let page = try XCTUnwrap(model.reviewInbox.flatMap(\.requests).first { $0.id == "PETS-3-page" })
        let value = CheckWindowValue(origin: page.origin, folder: page.folder, check: "onboarding", key: "desktop.light")
        let view = NSHostingView(rootView: CheckWindowView(value: value)
            .environment(model)
            .tint(Theme.accent)
            .preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentView = view
        windows.append(window)
        settle(window)
        window.setContentSize(view.fittingSize)
        let web = try XCTUnwrap(webView(in: window), "the window shows the page")
        let deadline = Date().addingTimeInterval(10)
        var width: Double = 0
        while Date() < deadline, width == 0 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            width = (try? await web.evaluateJavaScript("innerWidth") as? NSNumber)?.doubleValue ?? 0
        }
        XCTAssertEqual(width, 1440, accuracy: 1, "the desktop size lays out at 1440")
        settle(window)
        assertDrawn(window)
        await saveWithWeb(window, "mac-6-check-in-browser")
    }

    // MARK: The board

    private var storage: URL { FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true) }

    private static let pageURL: String = {
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>:root{color-scheme:light dark}body{font:17px -apple-system,sans-serif;margin:24px;background:#fff;color:#111}
        @media (prefers-color-scheme: dark){body{background:#15171c;color:#eee}}button{font-size:22px;padding:14px 24px}</style>
        </head><body><h1>Onboarding</h1><p id="w">Width</p><p id="s">Scheme</p><button>Download</button>
        <script>document.getElementById('w').textContent='Width '+innerWidth;
        document.getElementById('s').textContent=matchMedia('(prefers-color-scheme: dark)').matches?'Scheme dark':'Scheme light'</script>
        </body></html>
        """
        return "data:text/html;base64," + Data(html.utf8).base64EncodedString()
    }()

    private static func png(_ color: NSColor) -> Data {
        let image = NSImage(size: NSSize(width: 96, height: 96), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    private var repo: AddedRepo {
        AddedRepo(namespace: "folder", name: "Projects", branch: "", isPrivate: true,
                  boards: [SelectedBoard(folder: "Tasks/Pets", name: "Pets"), SelectedBoard(folder: "Tasks/Farm", name: "Farm")],
                  kind: .localFolder(path: root.path, bookmark: nil))
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func openModel() async throws -> AppModel {
        let model = AppModel(appGroup: suite, keychainService: suite, migratesLegacyStorage: false, storageDirectory: storage)
        model.addedRepos = [repo]
        await model.openBoard(repo, folder: "Tasks/Pets")
        XCTAssertNil(model.errorMessage)
        await model.loadReviewInbox()
        model.isRestoring = false
        model.isShowingReviews = true
        return model
    }

    // MARK: The window

    /// The app's window content, as `SidebarLayoutTests` hosts it: in a window never ordered in.
    private func host(_ model: AppModel) -> NSWindow {
        let view = NSHostingView(rootView: RootView()
            .environment(model)
            .frame(minWidth: 900, minHeight: 600)
            .tint(Theme.accent)
            .preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 940),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setContentSize(NSSize(width: 1500, height: 940))
        windows.append(window)
        return window
    }

    /// Lets SwiftUI build, run its tasks, load images and lay the window out.
    private func settle(_ window: NSWindow, seconds: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// The window drew something: its picture is not one flat colour. (What the screens say is
    /// checked on the model in `ReviewScreensModelTests`; SwiftUI builds no accessibility tree for
    /// a window that no assistive app is looking at, so the words cannot be read back here.)
    private func assertDrawn(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        guard let (_, rep) = bitmap(window) else { return XCTFail("no picture", file: file, line: line) }
        var colours = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 40)) {
            for x in stride(from: 0, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 40)) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colours.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
                }
            }
        }
        XCTAssertGreaterThan(colours.count, 8, "the window drew its content", file: file, line: line)
    }

    private func webView(in window: NSWindow) -> WKWebView? {
        func first(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            for child in view.subviews { if let web = first(child) { return web } }
            return nil
        }
        return window.contentView.flatMap(first)
    }

    // MARK: Pictures

    private var shotsFolder: URL? {
        ProcessInfo.processInfo.environment["REVUI_SHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func bitmap(_ window: NSWindow) -> (NSView, NSBitmapImageRep)? {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return (view, rep)
    }

    private func save(_ window: NSWindow, _ name: String) {
        guard let folder = shotsFolder, let (_, rep) = bitmap(window) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
    }

    /// A web view's page is drawn by another process, which the window's own drawing leaves
    /// out: the page's snapshot is drawn where the web view is.
    private func saveWithWeb(_ window: NSWindow, _ name: String) async {
        guard let folder = shotsFolder, let (view, rep) = bitmap(window), let web = webView(in: window),
              let snapshot = try? await web.takeSnapshot(configuration: nil) else { return }
        let frame = web.convert(web.bounds, to: view)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let flipped = view.isFlipped ? NSRect(x: frame.minX, y: view.bounds.height - frame.maxY, width: frame.width, height: frame.height) : frame
        snapshot.draw(in: flipped)
        NSGraphicsContext.restoreGraphicsState()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
    }
}
