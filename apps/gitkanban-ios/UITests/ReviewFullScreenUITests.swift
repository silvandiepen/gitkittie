import XCTest

/// The full-screen review viewer on the long review request: tap a file's picture, swipe to the
/// next file, decide there, and land on the next file that waits, with Undo on offer. Changes
/// asks for a message first. Needs the long request: run
/// `scripts/seed-long-review-fixture.sh <simulator-udid>` first (the app has to be installed);
/// without it the Reviews row is missing and the test skips.
///
/// `testCaptureRealRequests` takes screenshots of the screens Sil looks at when the fixture was
/// seeded with real requests (`--from <folder>` holding `Arvik/review/…`); it skips otherwise.
final class ReviewFullScreenUITests: XCTestCase {
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

    private func waitFor(_ label: String, on element: XCUIElement, timeout: TimeInterval = 10) {
        wait(for: [expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: element)], timeout: timeout)
    }

    /// The app's own notification prompt keeps it inactive, and reviews load once it is active.
    private func passPermissionPrompt() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    private func openReviews(_ app: XCUIApplication, skipMessage: String) throws {
        passPermissionPrompt()
        let row = app.buttons["homeReviewsRow"]
        guard row.waitForExistence(timeout: 15) else { throw XCTSkip(skipMessage) }
        row.tap()
    }

    private func openRequest(_ title: String, in app: XCUIApplication) {
        let request = app.staticTexts[title]
        XCTAssertTrue(request.waitForExistence(timeout: 10), "The request is listed.\n\(app.debugDescription)")
        request.tap()
        XCTAssertTrue(app.staticTexts["reviewAnsweredCount"].waitForExistence(timeout: 10))
    }

    /// Choose a filter in the request's ⋯ menu, by the start of its title ("All (86)").
    private func show(_ option: String, in app: XCUIApplication) {
        app.buttons["reviewMoreMenu"].tap()
        let predicate = NSPredicate(format: "label BEGINSWITH %@", option + " (")
        var choice = app.buttons.matching(predicate).firstMatch
        if !choice.waitForExistence(timeout: 3) {
            app.buttons["Show"].tap()
            choice = app.buttons.matching(predicate).firstMatch
        }
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "\(option) is in the menu.\n\(app.debugDescription)")
        choice.tap()
    }

    func testOpenFullScreenSwipeDecideAndAdvance() throws {
        let app = XCUIApplication()
        app.launch()
        try openReviews(app, skipMessage: "No board with the long review: run scripts/seed-long-review-fixture.sh first")
        openRequest("Long review, round 1", in: app)

        // From the question to the first file that waits, then open its picture full screen.
        app.buttons["reviewNextWaiting"].tap()
        XCTAssertTrue(app.staticTexts["tile-07"].waitForExistence(timeout: 10))
        let picture = app.descendants(matching: .any)["reviewAssetImage"].firstMatch
        XCTAssertTrue(picture.waitForExistence(timeout: 10))
        picture.tap()

        let viewer = app.otherElements["reviewFullScreen"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 10), "The picture opens full screen.\n\(app.debugDescription)")
        let position = app.staticTexts["fullScreenPosition"]
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        XCTAssertEqual(position.label, "1 of 54", "starts at the tapped file, among the 54 files on show")
        XCTAssertEqual(app.staticTexts["fullScreenTitle"].label, "tile-07")
        shot(app, "full-screen-open")

        // Swipe to the next file.
        app.swipeLeft()
        waitFor("2 of 54", on: position)
        XCTAssertEqual(app.staticTexts["fullScreenTitle"].label, "tile-08")
        shot(app, "full-screen-swiped")

        // Changes asks for a message before anything is sent; the send button waits for text.
        app.buttons["fullScreenChanges"].tap()
        let field = app.textViews["changeCommentField"].exists ? app.textViews["changeCommentField"] : app.textFields["changeCommentField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Changes opens the message sheet.\n\(app.debugDescription)")
        let send = app.buttons["changeCommentSend"]
        XCTAssertFalse(send.isEnabled, "Changes cannot be sent without a message")
        field.typeText("Make the background darker")
        XCTAssertTrue(send.isEnabled)
        shot(app, "change-needs-a-message")
        send.tap()

        // Sent: confirmed with Undo, and on to the next file that waits.
        XCTAssertTrue(app.buttons["fullScreenUndo"].waitForExistence(timeout: 10), "A confirmation with Undo shows.\n\(app.debugDescription)")
        waitFor("3 of 54", on: position)
        XCTAssertEqual(app.staticTexts["fullScreenTitle"].label, "tile-09")
        shot(app, "advanced-after-changes")

        // Approve here and on to tile-10; Undo takes it back and returns to tile-09, waiting again.
        app.buttons["fullScreenApprove"].tap()
        waitFor("4 of 54", on: position)
        XCTAssertEqual(app.staticTexts["fullScreenTitle"].label, "tile-10")
        let undo = app.buttons["fullScreenUndo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        waitFor("3 of 54", on: position)
        XCTAssertEqual(app.staticTexts["fullScreenTitle"].label, "tile-09")
        XCTAssertTrue(app.staticTexts["fullScreenStatus-Waiting"].waitForExistence(timeout: 5), "Undo puts tile-09 back to waiting")

        // The message written on tile-08 is offered on the next Changes, and one tap fills it in.
        app.buttons["fullScreenChanges"].tap()
        let suggestion = app.buttons["Make the background darker"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "The earlier comment is offered.\n\(app.debugDescription)")
        shot(app, "suggestion-offered")
        suggestion.tap()
        XCTAssertTrue(app.buttons["changeCommentSend"].isEnabled, "One tap fills the message")
        app.buttons["changeCommentCancel"].tap()

        // tile-08 kept its decision: swipe back to it.
        app.swipeRight()
        waitFor("2 of 54", on: position)
        XCTAssertTrue(app.staticTexts["fullScreenStatus-Changes requested"].waitForExistence(timeout: 5))
        shot(app, "decided-file-stays")

        // Swipe down closes the viewer.
        app.swipeDown()
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 10), "Swiping down closes the viewer.\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["reviewAnsweredCount"].exists)
    }

    func testCaptureRealRequests() throws {
        let app = XCUIApplication()
        app.launch()
        passPermissionPrompt()
        let arvik = app.staticTexts["Arvik"]
        guard app.buttons["homeReviewsRow"].waitForExistence(timeout: 15), arvik.waitForExistence(timeout: 10) else {
            throw XCTSkip("Seed with --from <folder holding Arvik/review> to capture the real requests")
        }
        shot(app, "home")

        app.buttons["homeReviewsRow"].tap()
        XCTAssertTrue(app.staticTexts["Minimal info panels, round 3 (build cards, stable, iPad menu)"].waitForExistence(timeout: 15))
        shot(app, "inbox")

        openRequest("Minimal info panels, round 3 (build cards, stable, iPad menu)", in: app)
        sleep(2)
        shot(app, "request")

        app.buttons["reviewMoreMenu"].tap()
        let select = app.buttons["reviewSelectFiles"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        sleep(3)
        shot(app, "select-grid")
        app.buttons["reviewSelectDone"].tap()

        // Everything on show: what is answered steps back, what waits is tagged.
        show("All", in: app)
        app.buttons["reviewMoreMenu"].tap()
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        sleep(3)
        app.swipeUp()
        sleep(2)
        shot(app, "select-grid-all")
        app.buttons["reviewSelectDone"].tap()
        show("Waiting", in: app)

        let picture = app.descendants(matching: .any)["reviewAssetImage"].firstMatch
        if picture.waitForExistence(timeout: 5) {
            picture.tap()
            sleep(3)
            shot(app, "full-screen")
            let pinch = app.otherElements["reviewFullScreen"]
            if pinch.exists {
                pinch.pinch(withScale: 2.5, velocity: 2)
                sleep(1)
                shot(app, "full-screen-zoomed")
            }
        }
    }
}
