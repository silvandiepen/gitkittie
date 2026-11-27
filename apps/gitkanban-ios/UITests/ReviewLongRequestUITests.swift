import XCTest

/// End-to-end on a long review request: what waits is shown and counted, the filter switches
/// between what waits and what is answered, Next Waiting goes to the next file without an
/// answer, and the notes read as formatted Markdown. Needs a board with the long request:
/// run `scripts/seed-long-review-fixture.sh <simulator-udid>` first (the app has to be
/// installed). Without it the Reviews row is missing and this test skips.
final class ReviewLongRequestUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitFor(_ label: String, on element: XCUIElement) {
        wait(for: [expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: element)], timeout: 10)
    }

    /// Opens a request and returns its answered count.
    private func open(_ title: String, in app: XCUIApplication) throws -> XCUIElement {
        // A permission prompt keeps the app inactive, and reviews load once it is active.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let row = app.buttons["homeReviewsRow"]
        guard row.waitForExistence(timeout: 15) else {
            throw XCTSkip("No board with the long review: run scripts/seed-long-review-fixture.sh first")
        }
        row.tap()
        let request = app.staticTexts[title]
        XCTAssertTrue(request.waitForExistence(timeout: 10), "The request is listed.\n\(app.debugDescription)")
        request.tap()
        let answered = app.staticTexts["reviewAnsweredCount"]
        XCTAssertTrue(answered.waitForExistence(timeout: 10))
        return answered
    }

    /// Choose a filter in the request's ⋯ menu.
    private func show(_ option: String, in app: XCUIApplication) {
        app.buttons["reviewMoreMenu"].tap()
        var choice = app.buttons[option]
        if !choice.waitForExistence(timeout: 3) {
            app.buttons["Show"].tap()
            choice = app.buttons[option]
        }
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "\(option) is in the menu.\n\(app.debugDescription)")
        choice.tap()
    }

    func testLongRequestShowsWhatWaitsAndReadsItsNotes() throws {
        let app = XCUIApplication()
        app.launch()
        let answered = try open("Long review, round 1", in: app)

        // Waiting: the six approved tiles are left out, even though their group still has
        // tiles waiting; the question and 54 tiles are on show, none answered.
        XCTAssertEqual(answered.label, "0 of 55 answered")
        shot(app, "waiting")

        // The notes are drawn as Markdown: the heading without its marks, nothing raw.
        app.buttons["reviewNotesButton"].tap()
        XCTAssertTrue(app.staticTexts["How these were made"].waitForExistence(timeout: 10),
                      "The notes' heading shows.\n\(app.debugDescription)")
        for raw in ["## ", "![", "**", "`", "|---"] {
            XCTAssertEqual(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", raw)).count, 0,
                           "Raw Markdown \(raw) in the notes.\n\(app.debugDescription)")
        }
        shot(app, "notes")
        app.buttons["Done"].tap()

        // Next Waiting: from the question (first) to the first tile without an answer.
        let next = app.buttons["reviewNextWaiting"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(app.staticTexts["tile-07"].waitForExistence(timeout: 10), "Next Waiting goes to tile-07.\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Waiting for you"].exists, "A file without a decision says so.")
        shot(app, "next-waiting")

        // Answered: only the six approved tiles.
        show("Answered (6)", in: app)
        waitFor("6 of 6 answered", on: answered)
        shot(app, "answered")

        // Everything.
        show("All (61)", in: app)
        waitFor("6 of 61 answered", on: answered)
        show("Waiting (55)", in: app)
        waitFor("0 of 55 answered", on: answered)
    }
}
