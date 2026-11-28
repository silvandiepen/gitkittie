import XCTest

/// End-to-end: choose several files of a review request and act on them at once. Needs a
/// board with a request of several files: run `scripts/seed-select-fixture.sh <simulator-udid>`
/// first (the app has to be installed). Without it the Reviews row is missing and this test skips.
final class ReviewSelectUITests: XCTestCase {
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

    /// Select in the request's ⋯ menu shows the files as a grid; Select All chooses them all;
    /// approving both options of a pick-one group is refused with a message; approving the
    /// rest decides them at once; a comment goes to the chosen files.
    func testSelectManyFilesAndActOnThemAtOnce() throws {
        let app = XCUIApplication()
        app.launch()
        let row = app.buttons["homeReviewsRow"]
        guard row.waitForExistence(timeout: 15) else {
            throw XCTSkip("No board with a review of several files: run scripts/seed-select-fixture.sh first")
        }
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        row.tap()

        let request = app.staticTexts["Pet icons, round 1"]
        XCTAssertTrue(request.waitForExistence(timeout: 10), "The request is listed.\n\(app.debugDescription)")
        request.tap()
        let answered = app.staticTexts["reviewAnsweredCount"]
        XCTAssertTrue(answered.waitForExistence(timeout: 10))
        XCTAssertEqual(answered.label, "0 of 5 answered")

        // ⋯ → Select: the files as a grid.
        app.buttons["reviewMoreMenu"].tap()
        let select = app.buttons["reviewSelectFiles"]
        XCTAssertTrue(select.waitForExistence(timeout: 5), "Select is in the request's menu.\n\(app.debugDescription)")
        select.tap()
        let cat = app.buttons["reviewSelectItem-icon-cat"]
        XCTAssertTrue(cat.waitForExistence(timeout: 10), "Select mode shows the files.\n\(app.debugDescription)")
        let count = app.staticTexts["reviewSelectionCount"]
        XCTAssertEqual(count.label, "Select files")

        // Select All, then Approve: the pick-one group says no, and nothing changes.
        app.buttons["reviewSelectAll"].tap()
        XCTAssertEqual(count.label, "5 selected")
        XCTAssertTrue(cat.isSelected)
        shot(app, "select-all")
        app.buttons["reviewSelectionApprove"].tap()
        let refusal = app.staticTexts["“bowl” is pick one: approve only one of its options, not bowl-red and bowl-blue."]
        XCTAssertTrue(refusal.waitForExistence(timeout: 10), "Approving both options is refused.\n\(app.debugDescription)")
        XCTAssertEqual(answered.label, "0 of 5 answered")
        shot(app, "pick-one-refused")

        // Leave one option out: the other four are approved at once.
        app.buttons["reviewSelectItem-bowl-blue"].tap()
        XCTAssertEqual(count.label, "4 selected")
        app.buttons["reviewSelectionApprove"].tap()
        wait(for: [expectation(for: NSPredicate(format: "label == '4 of 5 answered'"), evaluatedWith: answered)], timeout: 10)

        // A comment on two of them.
        app.buttons["reviewSelectAll"].tap() // all were not chosen: this chooses all
        app.buttons["reviewSelectAll"].tap() // and this clears them
        XCTAssertEqual(count.label, "Select files")
        cat.tap()
        app.buttons["reviewSelectItem-icon-dog"].tap()
        XCTAssertEqual(count.label, "2 selected")
        app.buttons["reviewSelectionComment"].tap()
        let field = app.descendants(matching: .any)["changeCommentField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The comment sheet opens.\n\(app.debugDescription)")
        field.tap()
        field.typeText("Thinner lines")
        app.buttons["changeCommentSend"].tap()
        shot(app, "commented")

        // Done: back to the slides, where the comment shows on the first file.
        app.buttons["reviewSelectDone"].tap()
        XCTAssertTrue(app.staticTexts["Thinner lines"].waitForExistence(timeout: 10),
                      "The comment is on the selected file.\n\(app.debugDescription)")
        shot(app, "comment-on-slide")
    }
}
