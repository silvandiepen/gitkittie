import AppKit
import GitKanbanKit
import GitKittieKit
import SwiftUI
import XCTest

/// The window's sidebar stays on screen whatever the "Not sent" banner under the board holds
/// (GITKITTIE-121). The real `RootView` is hosted in a window that is never shown, over a real
/// folder board and a real outbox in a temporary folder.
///
/// What went wrong: a refused change whose note is long ("Nothing was stored on this device
/// for this change to …") showed in the banner with its note fixed to its full height. A
/// window's content asks its views how small they can be by offering them no width, and at
/// no width that note wraps after every character: the banner, and so the window's content,
/// claimed some 2,500 pt of height. The window could not grow that tall, so the split view
/// overflowed it, centred: the sidebar's rows sat above the top of the window, its footer
/// and the banner below the bottom, and the sidebar looked empty. It stayed that way for as
/// long as that one change was in the outbox — through toggling the sidebar and relaunching.
@MainActor
final class SidebarLayoutTests: XCTestCase {
    private let suite = "gk-sidebar-\(UUID().uuidString)"
    private var root: URL!
    private var windows: [NSWindow] = []
    /// Each window's height as it was made, before SwiftUI filled it.
    private var requestedHeight: [ObjectIdentifier: CGFloat] = [:]

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite + "-board", isDirectory: true)
        try write("Tasks/README.md", """
        ---
        config: board
        lanes:
          - id: todo
            name: To do
            folder: "1. To do"
            status: todo
          - id: done
            name: Done
            folder: "5. Done"
            status: done
            terminal: true
        ---
        """)
        for project in ["Morrow", "Pets", "Farm"] {
            try write("Tasks/\(project)/README.md", "---\nconfig: project\nproject: \(project)\nlanes: []\n---\n")
            try write("Tasks/\(project)/1. To do/\(project.uppercased())-1.md", CardText.make(
                id: "\(project.uppercased())-1", title: "First", project: project, status: "todo",
                priority: nil, type: nil, assignee: nil, order: "1", body: "# First"))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Tasks/\(project)/5. Done"),
                                                    withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        let defaults = UserDefaults(suiteName: suite)
        defaults?.removePersistentDomain(forName: suite)
        defaults?.synchronize()
        let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences/\(suite).plist")
        try? FileManager.default.removeItem(at: preferences)
        try? FileManager.default.removeItem(at: storage)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Tests

    /// Sil's state since 27 Nov: one refused write whose content is not on this device. On
    /// launch, whatever the window's size, the sidebar's rows are in the window.
    func testALongRefusalUnderTheBoardLeavesTheSidebarInTheWindow() async throws {
        try queue([stale])
        let model = try await openModel()
        XCTAssertEqual(model.failedSyncItems.map(\.id), ["stale"])

        for size in [NSSize(width: 1350, height: 799), NSSize(width: 900, height: 600), NSSize(width: 1800, height: 1100)] {
            let window = host(model, size: size)
            assertSidebarOnScreen(in: window, "\(Int(size.width))×\(Int(size.height))")
        }
    }

    /// What Sil did: three refused writes (the banner is one line with Retry All), Retry All,
    /// the two that can be sent go out again, and the one that cannot stays — the banner then
    /// shows it with its note. The sidebar stays in the window throughout.
    func testRetryAllDownToOneLongRefusalLeavesTheSidebarInTheWindow() async throws {
        try queue([stale, try sendable("a"), try sendable("b")])
        let model = try await openModel()
        XCTAssertEqual(model.failedSyncItems.count, 3)

        let window = host(model, size: NSSize(width: 1350, height: 799))
        assertSidebarOnScreen(in: window, "with three refused writes")

        await model.retryAllFailedSync()
        // The two with their content are on their way again (outbox writes need a provider
        // repository, so here they wait for one); the one without stays refused.
        XCTAssertEqual(model.failedSyncItems.map(\.id), ["stale"])
        XCTAssertEqual(Set(model.syncItems.filter { $0.state != .failed }.map(\.id)), ["a", "b"])
        settle(window)
        assertSidebarOnScreen(in: window, "after Retry All")
    }

    // MARK: The board and the outbox

    private var storage: URL { FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true) }

    private var repo: AddedRepo {
        AddedRepo(namespace: "folder", name: "Projects", branch: "", isPrivate: true,
                  boards: [SelectedBoard(folder: "Tasks/Morrow", name: "Morrow"),
                           SelectedBoard(folder: "Tasks/Pets", name: "Pets"),
                           SelectedBoard(folder: "Tasks/Farm", name: "Farm")],
                  kind: .localFolder(path: root.path, bookmark: nil))
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// The review write Sil's Mac could not store (the disk was full), with the note the
    /// outbox gives it.
    private var stale: [String: Any] {
        let path = "Arvik/review/ARVIK-471-unit-reply-timing/review.md"
        return operation("stale", path: path, note: OutboxError.contentMissing(path: path).errorDescription!)
    }

    /// A refused card write whose content is on this device, so Retry All sends it again.
    private func sendable(_ id: String) throws -> [String: Any] {
        let blob = outboxDirectory.appendingPathComponent("\(id).blob")
        try FileManager.default.createDirectory(at: outboxDirectory, withIntermediateDirectories: true)
        try Data(CardText.make(id: "MORROW-\(id)", title: "Sent", project: "Morrow", status: "todo",
                               priority: nil, type: nil, assignee: nil, order: "2", body: "# Sent").utf8).write(to: blob)
        return operation(id, path: "Tasks/Morrow/1. To do/MORROW-\(id).md", note: "Refused")
    }

    private func operation(_ id: String, path: String, note: String) -> [String: Any] {
        ["id": id, "repoKey": repo.id, "kind": "write", "path": path, "message": "Change \(id)",
         "createdAt": 0, "state": "failed", "note": note, "attempts": 1]
    }

    private var outboxDirectory: URL { storage.appendingPathComponent("Outbox", isDirectory: true) }

    /// The outbox's index as it is on disk.
    private func queue(_ operations: [[String: Any]]) throws {
        try FileManager.default.createDirectory(at: outboxDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: operations).write(to: outboxDirectory.appendingPathComponent("outbox.json"))
    }

    private func openModel() async throws -> AppModel {
        let model = AppModel(appGroup: suite, keychainService: suite, migratesLegacyStorage: false, storageDirectory: storage)
        model.addedRepos = [repo]
        await model.openBoard(repo, folder: "Tasks/Morrow")
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.board)
        await model.refreshSyncItems()
        model.isRestoring = false
        return model
    }

    // MARK: The window

    /// The app's window content (`GitKanbanApp`) in a window that is never ordered in, made
    /// the way SwiftUI makes a `WindowGroup` window: content under the title bar
    /// (`.fullSizeContentView`) and a unified toolbar. Without them macOS 15 refuses the
    /// sidebar-tracking separator SwiftUI puts in the toolbar for a `NavigationSplitView`
    /// ("Cannot register more than one NSTrackingSeparatorToolbarItem that tracks the same
    /// divider") and the test process dies.
    private func host(_ model: AppModel, size: NSSize) -> NSWindow {
        let view = NSHostingView(rootView: RootView()
            .environment(model)
            .frame(minWidth: 900, minHeight: 600)
            .tint(Theme.accent)
            .preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setContentSize(size)
        requestedHeight[ObjectIdentifier(window)] = window.frame.height
        windows.append(window)
        settle(window)
        return window
    }

    /// Lets SwiftUI build, run its tasks and lay the window out until the sidebar has rows.
    private func settle(_ window: NSWindow) {
        let deadline = Date().addingTimeInterval(5)
        var stableRounds = 0
        var last: NSRect?
        while Date() < deadline, stableRounds < 5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
            let frame = splitView(in: window).map { $0.convert($0.bounds, to: nil) }
            let rows = outline(in: window)?.numberOfRows ?? 0
            stableRounds = (frame != nil && frame == last && rows > 0) ? stableRounds + 1 : 0
            last = frame
        }
    }

    private func assertSidebarOnScreen(in window: NSWindow, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let content = window.contentView else { return XCTFail("no content view", file: file, line: line) }
        guard let split = splitView(in: window) else { return XCTFail("\(context): no split view", file: file, line: line) }
        guard let list = outline(in: window), list.numberOfRows > 0 else {
            return XCTFail("\(context): the sidebar has no rows", file: file, line: line)
        }
        // The window keeps the size it was given (plus its toolbar): the content has to fit
        // it, not push it to the height the content asks for.
        XCTAssertLessThan(window.frame.height, requestedHeight[ObjectIdentifier(window)].map { $0 + 120 } ?? .infinity,
                          "\(context): the window grew to \(window.frame)", file: file, line: line)
        let visible = content.bounds
        let splitFrame = split.convert(split.bounds, to: nil)
        XCTAssertLessThanOrEqual(splitFrame.height, visible.height + 1,
                                 "\(context): the split view is taller than the window (\(splitFrame) in \(visible))",
                                 file: file, line: line)
        // All Tasks, the first row, is where the top of the sidebar is: below the toolbar.
        let firstRow = list.convert(list.rect(ofRow: 0), to: nil)
        XCTAssertTrue(window.contentLayoutRect.contains(firstRow),
                      "\(context): the sidebar's first row \(firstRow) is outside the window \(window.contentLayoutRect)",
                      file: file, line: line)
    }

    private func splitView(in window: NSWindow) -> NSSplitView? {
        window.contentView.flatMap { first(NSSplitView.self, in: $0) }
    }

    /// The sidebar's list (a `List` with `.sidebar` style is an outline view on the Mac), in
    /// the split view's first column.
    private func outline(in window: NSWindow) -> NSTableView? {
        splitView(in: window)?.arrangedSubviews.first.flatMap { first(NSTableView.self, in: $0) }
    }

    private func first<V: NSView>(_ type: V.Type, in view: NSView) -> V? {
        if let match = view as? V { return match }
        for child in view.subviews { if let match = first(type, in: child) { return match } }
        return nil
    }
}
