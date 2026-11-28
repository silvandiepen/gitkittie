import XCTest

/// End-to-end on iPhone: a review whose last decision moves its card (banner, Undo), and a
/// browser check (open full screen, answer the checklist, a scaled size, decide). Needs the
/// board of `scripts/seed-review-actions-fixture.sh <simulator-udid>` (the app has to be
/// installed first); without it the Reviews row is missing and these tests skip.
final class ReviewActionsCheckUITests: XCTestCase {
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

    /// Launch, open the Reviews list and say who you are on the board (Sil), as the list asks.
    private func openReviews() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        let row = app.buttons["homeReviewsRow"]
        guard row.waitForExistence(timeout: 15) else {
            throw XCTSkip("No board with review actions: run scripts/seed-review-actions-fixture.sh first")
        }
        // The app's own notification prompt, on its first launch.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        row.tap()
        let sil = app.buttons["reviewIdentity-sil"]
        if sil.waitForExistence(timeout: 8) {
            shot(app, "which-one-are-you")
            sil.tap()
        }
        return app
    }

    /// Accepting the last waiting file runs the request's action: "Moved PETS-1 to Testing"
    /// with Undo; Undo takes it back, and the request's Actions say so.
    func testDecidingTheLastFileMovesTheCardAndUndoTakesItBack() throws {
        let app = try openReviews()
        let request = app.staticTexts["Site onboarding, round 1"]
        XCTAssertTrue(request.waitForExistence(timeout: 10), "The request is listed.\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Due tomorrow"].exists || app.descendants(matching: .any)["reviewDue"].exists)
        shot(app, "reviews-list")
        request.tap()

        let whenDecided = app.buttons["reviewWhenDecidedButton"]
        XCTAssertTrue(whenDecided.waitForExistence(timeout: 10), "The request says what deciding it does.\n\(app.debugDescription)")
        XCTAssertTrue(whenDecided.label.contains("Accept → move PETS-1 to Testing"), whenDecided.label)
        XCTAssertTrue(app.descendants(matching: .any)["reviewRoundTag"].exists, "badge revises an earlier one: Round 2")
        shot(app, "request-with-actions")

        app.buttons["Approve"].firstMatch.tap()
        let message = app.staticTexts["reviewActionMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 10), "The banner says what moved.\n\(app.debugDescription)")
        XCTAssertEqual(message.label, "Moved PETS-1 to Testing")
        shot(app, "moved-banner")

        app.buttons["reviewActionUndo"].tap()
        let gone = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: gone, evaluatedWith: message)], timeout: 10)

        app.buttons["reviewWhenDecidedButton"].tap()
        let undone = app.staticTexts["Moved PETS-1 to Testing · undone"]
        XCTAssertTrue(undone.waitForExistence(timeout: 10), "The Actions history shows the undo.\n\(app.debugDescription)")
        shot(app, "actions-history-undone")
    }

    /// A browser check: open it, answer the checklist at the phone's own size, look at the
    /// desktop size as a scaled preview (the page lays out at 1440 and a tap lands on its
    /// button), and ask for changes with the failed line filled in.
    func testABrowserCheckIsAnsweredAndDecided() throws {
        let app = try openReviews()
        let request = app.staticTexts["Onboarding page check"]
        XCTAssertTrue(request.waitForExistence(timeout: 10), "The request for Sil is listed.\n\(app.debugDescription)")
        request.tap()

        let open = app.buttons["checkOpen"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "The check is a page of the request.\n\(app.debugDescription)")
        XCTAssertTrue(app.descendants(matching: .any)["checkWaiting"].exists, "A check waits until it is decided")
        shot(app, "check-row")
        open.tap()

        // The page at the phone's own width, the checklist in a sheet.
        let width = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Width '")).firstMatch
        XCTAssertTrue(width.waitForExistence(timeout: 15), "The page loads.\n\(app.debugDescription)")
        XCTAssertTrue(app.descendants(matching: .any)["checkSizeBadge"].exists)
        let pass = app.buttons["checkPass-hero"]
        XCTAssertTrue(pass.waitForExistence(timeout: 10), "The checklist sheet is up.\n\(app.debugDescription)")
        pass.tap()
        app.buttons["checkFail-cta"].tap()
        let note = app.descendants(matching: .any)["checkNoteField-cta"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("Below the fold")
        app.buttons["checkNoteSave-cta"].tap()
        let progress = app.staticTexts["checkSizeProgress"]
        wait(for: [expectation(for: NSPredicate(format: "label == '2 of 2 answered'"), evaluatedWith: progress)], timeout: 5)
        shot(app, "check-answered")

        // Desktop: a scaled preview, laid out at its true width; a tap lands on the button.
        app.buttons["checkSizeMenu"].tap()
        let desktop = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Desktop'")).firstMatch
        XCTAssertTrue(desktop.waitForExistence(timeout: 5), "\(app.debugDescription)")
        desktop.tap()
        XCTAssertTrue(app.descendants(matching: .any)["checkScaledPreview"].waitForExistence(timeout: 5))
        let wide = app.webViews.staticTexts["Width 1440"]
        XCTAssertTrue(wide.waitForExistence(timeout: 15), "The page lays out at 1440.\n\(app.debugDescription)")
        let button = app.webViews.buttons["Tap me"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        XCTAssertTrue(app.webViews.buttons["Tapped"].waitForExistence(timeout: 5), "The tap landed on the scaled button")
        shot(app, "check-desktop-scaled")

        // Changes, with the failed line filled in.
        app.buttons["checkDecisionChanges"].tap()
        let field = app.descendants(matching: .any)["changeCommentField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The message sheet opens.\n\(app.debugDescription)")
        XCTAssertTrue((field.value as? String ?? "").contains("The button shows without scrolling — Below the fold"),
                      "Changes starts from the failed line: \(field.value ?? "")")
        shot(app, "check-changes-message")
        app.buttons["changeCommentSend"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["checkDecided-Changes requested"].waitForExistence(timeout: 10),
                      "The check is decided.\n\(app.debugDescription)")
        shot(app, "check-decided")
        app.buttons["checkClose"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["checkStatus-Changes requested"].waitForExistence(timeout: 10))
        shot(app, "check-row-decided")
    }

    /// Someone else's request: listed under Everyone only, read-only with comments allowed.
    func testSomeoneElsesRequestIsReadOnly() throws {
        let app = try openReviews()
        XCTAssertTrue(app.staticTexts["Site onboarding, round 1"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Copy for the store"].exists, "For me hides Herma's request")
        app.buttons["reviewAssignmentMenu"].tap()
        app.buttons["Everyone"].tap()
        let theirs = app.staticTexts["Copy for the store"]
        XCTAssertTrue(theirs.waitForExistence(timeout: 5), "Everyone shows it.\n\(app.debugDescription)")
        shot(app, "everyone")
        theirs.tap()
        XCTAssertTrue(app.staticTexts["For Herma. You can comment."].waitForExistence(timeout: 10), "\(app.debugDescription)")
        XCTAssertFalse(app.buttons["Approve"].firstMatch.isEnabled, "Decisions are disabled")
        shot(app, "read-only")
        // Back to For me for the next run (its file still waits: close anyway).
        app.buttons["reviewBackButton"].tap()
        let closeAnyway = app.buttons["Close Anyway"]
        if closeAnyway.waitForExistence(timeout: 3) { closeAnyway.tap() }
        app.buttons["reviewAssignmentMenu"].tap()
        app.buttons["For Me"].tap()
    }
}
