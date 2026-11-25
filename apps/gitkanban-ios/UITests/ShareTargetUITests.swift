import XCTest

/// Tasks is offered in the system share sheet for an image however the sharing app hands it
/// over (an image, its bytes, a file, alongside a link or text), and not for plain text,
/// links or other files. The app opens the share sheet itself (`ShareSheetProbe`, a DEBUG
/// hook) on one representation per launch, so the real activation rules decide.
///
/// The share sheet shows a few apps in its row and the rest under "More"; actions likewise.
/// A target counts as offered when it is in either place.
final class ShareTargetUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    /// Open the share sheet on `kind` and return the names of the apps and the actions it offers.
    private func offered(for kind: String) -> (apps: Set<String>, actions: Set<String>) {
        (names(kind, group: "shareCell"), names(kind, group: "actionGroupCell"))
    }

    private func names(_ kind: String, group: String) -> Set<String> {
        app.terminate()
        app.launchArguments = ["-shareSheetProbe", kind]
        app.launch()
        let sheet = app.collectionViews["activityCollectionView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 20), "The share sheet opens for \(kind).\n\(app.debugDescription)")
        let cells = app.cells.matching(identifier: group)
        _ = cells.firstMatch.waitForExistence(timeout: 10)
        settle(cells)
        var names = Set(labels { $0.elementType == .cell && $0.identifier == group })
        // A row ends in "More" only when it has more than fits; with few apps installed (a
        // fresh simulator) it does not, and everything is already in the row.
        let more = cells.matching(NSPredicate(format: "label == 'More'")).firstMatch
        if more.exists, more.isHittable {
            more.tap()
            _ = app.buttons["Done"].firstMatch.waitForExistence(timeout: 10)
            names.formUnion(labels { $0.elementType == .staticText || $0.elementType == .cell })
        }
        return names
    }

    /// Wait until the row stops gaining cells: the share sheet fills it in as targets load.
    private func settle(_ cells: XCUIElementQuery) {
        var last = -1
        for _ in 0..<10 {
            let count = cells.count
            if count == last { return }
            last = count
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// Labels read from one accessibility snapshot: querying element by element races the
    /// share sheet while it is still laying out.
    private func labels(where matches: (XCUIElementSnapshot) -> Bool) -> [String] {
        guard let root = try? app.snapshot() else { return [] }
        var found: [String] = []
        func walk(_ element: XCUIElementSnapshot) {
            if matches(element) { found.append(element.label) }
            element.children.forEach(walk)
        }
        walk(root)
        return found
    }

    private func assertOffered(_ kind: String, file: StaticString = #filePath, line: UInt = #line) {
        let offered = offered(for: kind)
        XCTAssertTrue(offered.apps.contains("Tasks"), "Tasks is a share target for \(kind). Offered: \(offered.apps.sorted())", file: file, line: line)
        XCTAssertTrue(offered.actions.contains("Add to Tasks"), "Add to Tasks is an action for \(kind). Offered: \(offered.actions.sorted())", file: file, line: line)
    }

    private func assertNotOffered(_ kind: String, file: StaticString = #filePath, line: UInt = #line) {
        let offered = offered(for: kind)
        XCTAssertFalse(offered.apps.contains("Tasks"), "Tasks is not a share target for \(kind)", file: file, line: line)
        XCTAssertFalse(offered.actions.contains("Add to Tasks"), "Add to Tasks is not an action for \(kind)", file: file, line: line)
    }

    func testOfferedForEveryImageRepresentation() {
        for kind in ["uiimage", "png-data", "jpeg-data", "png-file", "jpeg-file", "file-without-extension", "untyped-data",
                     "link-and-image", "text-and-image"] {
            assertOffered(kind)
        }
    }

    func testNotOfferedWithoutAnImage() {
        for kind in ["text", "link", "text-and-link", "pdf-file"] {
            assertNotOffered(kind)
        }
    }
}
