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
        model.reviewsFocusRequest = site.ref
        let window = host(model)
        settle(window) { self.find("reviewWhenDecided", in: window) != nil }

        XCTAssertEqual(labels("reviewWhenDecided", in: window), ["Accept → move PETS-1 to Testing", "Changes → move PETS-1 to In Progress"])
        XCTAssertNotNil(find("reviewIdentityPrompt", in: window), "Farm asks who you are")
        XCTAssertTrue(labels("reviewForChip", in: window).contains("For Sil"))
        XCTAssertTrue(labels("reviewDue", in: window).contains("Due tomorrow"))
        XCTAssertTrue(labels("reviewDue", in: window).contains("Due yesterday"))
        XCTAssertFalse(allLabels(in: window).contains("Copy for the store"), "For me hides Herma's request")
        XCTAssertTrue(labels("reviewingAs", in: window).contains { $0.contains("Sil") })
        save(window, "mac-1-reviews-actions")
    }

    /// Deciding the last file runs the action: the banner says what moved, with Undo; Undo
    /// takes it back and the Actions history says so.
    func testTheBannerAfterTheLastDecision() async throws {
        let model = try await openModel()
        let site = try XCTUnwrap(model.reviewInbox.flatMap(\.requests).first { $0.id == "PETS-1-site" })
        model.reviewsFocusRequest = site.ref
        let window = host(model)
        settle(window) { self.find("reviewWhenDecided", in: window) != nil }
        let decided = await model.decide(site, item: site.items[1], status: .approved)
        XCTAssertTrue(decided)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Tasks/Pets/4. Testing/PETS-1.md").path))
        settle(window) { self.find("reviewActionMessage", in: window) != nil }
        XCTAssertEqual(labels("reviewActionMessage", in: window), ["Moved PETS-1 to Testing"])
        XCTAssertNotNil(find("reviewActionUndo", in: window))
        XCTAssertTrue(labels("reviewActionHistory", in: window).contains("Moved PETS-1 to Testing"))
        save(window, "mac-2-moved-banner")

        let report = try XCTUnwrap(model.reviewActionReport)
        let undone = await model.undoReviewActions(model.reviewActionBanner(report))
        XCTAssertTrue(undone)
        settle(window) { self.labels("reviewActionHistory", in: window).contains("Moved PETS-1 to Testing · undone") }
        XCTAssertTrue(labels("reviewActionHistory", in: window).contains("Moved PETS-1 to Testing · undone"))
        XCTAssertNil(find("reviewActionMessage", in: window), "nothing left on the banner")
        save(window, "mac-3-undone")
    }

    /// Everyone: Herma's request is listed, read-only: the line on top says so and the decision
    /// buttons are off.
    func testSomeoneElsesRequestIsReadOnly() async throws {
        let model = try await openModel()
        model.reviewAssignmentFilter = .everyone
        let copy = try XCTUnwrap(model.reviewInbox.flatMap(\.requests).first { $0.id == "PETS-4-copy" })
        model.reviewsFocusRequest = copy.ref
        let window = host(model)
        settle(window) { self.find("reviewReadOnlyNotice", in: window) != nil }
        XCTAssertEqual(labels("reviewReadOnlyNotice", in: window), ["For Herma. You can comment."])
        XCTAssertTrue(allLabels(in: window).contains("Copy for the store"))
        save(window, "mac-4-everyone-read-only")
    }

    /// A browser check in the request: the sizes × appearance grid, the checklist's progress and
    /// what failed, and Check in Browser.
    func testACheckRow() async throws {
        let model = try await openModel()
        let page = try XCTUnwrap(model.reviewInbox.flatMap(\.requests).first { $0.id == "PETS-3-page" })
        model.reviewsFocusRequest = page.ref
        let window = host(model)
        settle(window) { self.find("checkGrid", in: window) != nil }
        XCTAssertNotNil(find("checkInBrowser", in: window))
        XCTAssertNotNil(find("checkWaiting", in: window), "a check waits until it is decided")
        XCTAssertEqual(labels("checkCell-phone.light", in: window), ["Phone, light: 1 fail"])
        XCTAssertEqual(labels("checkCell-desktop.light", in: window), ["Desktop, light: 1/2"])
        XCTAssertEqual(labels("checkCell-phone.dark", in: window), ["Phone, dark: Pending"])
        XCTAssertTrue(allLabels(in: window).contains { $0.contains("The button shows without scrolling — Below the fold") })
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
        window.setContentSize(view.fittingSize)
        windows.append(window)
        settle(window) { self.find("checkSizeProgress", in: window) != nil && self.webView(in: window)?.isLoading == false }
        let web = try XCTUnwrap(webView(in: window))
        let deadline = Date().addingTimeInterval(10)
        var width: Double = 0
        while Date() < deadline, width == 0 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            width = (try? await web.evaluateJavaScript("innerWidth") as? NSNumber)?.doubleValue ?? 0
        }
        XCTAssertEqual(width, 1440, accuracy: 1, "the desktop size lays out at 1440")
        XCTAssertEqual(labels("checkSizeProgress", in: window), ["1 of 2 answered"])
        XCTAssertNotNil(find("checkLine-hero", in: window))
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

    /// Lets SwiftUI build, run its tasks and lay out until `ready` (at most 8 seconds), then a
    /// little longer for images and the last layout pass.
    private func settle(_ window: NSWindow, until ready: () -> Bool) {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, !ready() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: What is on screen

    private func walk(_ element: Any, depth: Int = 0, _ visit: (NSAccessibilityProtocol) -> Void) {
        guard depth < 60, let node = element as? NSAccessibilityProtocol else { return }
        visit(node)
        for child in node.accessibilityChildren() ?? [] { walk(child, depth: depth + 1, visit) }
    }

    private func find(_ id: String, in window: NSWindow) -> NSAccessibilityProtocol? {
        var found: NSAccessibilityProtocol?
        if let content = window.contentView {
            walk(content) { node in if found == nil, node.accessibilityIdentifier() == id { found = node } }
        }
        return found
    }

    private func text(_ node: NSAccessibilityProtocol) -> String {
        if let label = node.accessibilityLabel(), !label.isEmpty { return label }
        if let value = node.accessibilityValue() as? String { return value }
        return node.accessibilityTitle() ?? ""
    }

    private func labels(_ id: String, in window: NSWindow) -> [String] {
        var result: [String] = []
        if let content = window.contentView {
            walk(content) { node in if node.accessibilityIdentifier() == id { result.append(text(node)) } }
        }
        return result
    }

    private func allLabels(in window: NSWindow) -> [String] {
        var result: [String] = []
        if let content = window.contentView { walk(content) { result.append(text($0)) } }
        return result
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
