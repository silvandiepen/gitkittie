import XCTest

/// The flow the iOS app exists for: choose a line of an old commit and open a pull request
/// that undoes it — against the offline demo, so it needs no account.
final class UndoFlowUITests: XCTestCase {
    func testUndoingAChosenLineOpensAPullRequest() throws {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "GITBUD_DEMO": "1",
            "GITBUD_COMMIT": "analytics",
            "GITBUD_FILE": "index.html",
        ]
        app.launch()

        let analytics = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'plausible'")).firstMatch
        XCTAssertTrue(analytics.waitForExistence(timeout: 15), "The diff of index.html shows the analytics line")
        analytics.tap()

        let undo = app.buttons["undoChosen"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Choosing a line shows the bar")
        attach(app, "1 chosen line")
        undo.tap()

        let open = app.buttons["openPullRequest"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        attach(app, "2 compose")
        open.tap()

        let opened = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Opened #'")).firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 10), "The pull request opens")
        attach(app, "3 opened")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
