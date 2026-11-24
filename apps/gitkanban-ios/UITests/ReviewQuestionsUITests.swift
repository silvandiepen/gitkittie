import XCTest

/// End-to-end: answer the questions of a review request on the iPhone. Needs a board with a
/// request that asks questions: run `scripts/seed-question-fixture.sh <simulator-udid>` first
/// (the app has to be installed). Without it the Reviews row is missing and this test skips.
final class ReviewQuestionsUITests: XCTestCase {
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

    private func option(_ app: XCUIApplication, _ question: String, _ id: String) -> XCUIElement {
        app.buttons["reviewOption-\(question)-\(id)"].firstMatch
    }

    /// A question shows as a page of its own: one answer for a single-choice question,
    /// several for a multiple-choice one, an answer of your own under Other, and the answer
    /// can be changed afterwards.
    func testQuestionsAreAnsweredOnePageAtATime() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        let row = app.buttons["homeReviewsRow"]
        guard row.waitForExistence(timeout: 15) else {
            throw XCTSkip("No board with review questions: run scripts/seed-question-fixture.sh first")
        }
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(row.label.contains("2"), "Both questions wait: \(row.label)")
        row.tap()

        let request = app.staticTexts["Food and toys for the cat"]
        XCTAssertTrue(request.waitForExistence(timeout: 10), "The request is listed.\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '2 questions'")).firstMatch.exists,
                      "Its row says it holds questions")
        shot(app, "inbox")
        request.tap()

        let answered = app.staticTexts["reviewAnsweredCount"]
        XCTAssertTrue(answered.waitForExistence(timeout: 10))
        XCTAssertEqual(answered.label, "0 of 2 answered")
        XCTAssertTrue(app.staticTexts["Which food should the cat get?"].waitForExistence(timeout: 5))

        // One choice: picking another option moves the choice.
        let fish = option(app, "food", "fish"), chicken = option(app, "food", "chicken")
        XCTAssertTrue(fish.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["reviewAnswerButton-food"].isEnabled, "Nothing to send before choosing")
        fish.tap()
        XCTAssertTrue(fish.isSelected)
        chicken.tap()
        XCTAssertTrue(chicken.isSelected)
        XCTAssertFalse(fish.isSelected, "A single-choice question holds one answer")
        shot(app, "single-choice")
        app.buttons["reviewAnswerButton-food"].tap()
        wait(for: [expectation(for: NSPredicate(format: "label == '1 of 2 answered'"), evaluatedWith: answered)], timeout: 10)

        // The deck moves on to the multiple-choice question.
        XCTAssertTrue(app.staticTexts["Which toys should we buy?"].waitForExistence(timeout: 10))
        let mouse = option(app, "toys", "mouse"), laser = option(app, "toys", "laser")
        mouse.tap()
        laser.tap()
        XCTAssertTrue(mouse.isSelected && laser.isSelected, "Several answers can be chosen")
        option(app, "toys", "other").tap()
        let own = app.textFields["reviewOtherField-toys"].firstMatch
        XCTAssertTrue(own.waitForExistence(timeout: 5))
        own.typeText("A cardboard box")
        shot(app, "multiple-choice")
        app.buttons["reviewAnswerButton-toys"].tap()
        wait(for: [expectation(for: NSPredicate(format: "label == '2 of 2 answered'"), evaluatedWith: answered)], timeout: 10)
        XCTAssertTrue(app.staticTexts["reviewAnswered-toys"].waitForExistence(timeout: 10) || app.otherElements["reviewAnswered-toys"].exists)
        shot(app, "answered")

        // Back to the first question: change the answer.
        app.swipeRight()
        let change = app.buttons["reviewChangeAnswer-food"]
        XCTAssertTrue(change.waitForExistence(timeout: 10), "An answer can be changed.\n\(app.debugDescription)")
        XCTAssertTrue(chicken.isSelected, "The answer shows as chosen")
        change.tap()
        fish.tap()
        app.buttons["reviewAnswerButton-food"].tap()
        XCTAssertTrue(change.waitForExistence(timeout: 10))
        XCTAssertTrue(fish.isSelected && !chicken.isSelected, "The changed answer is the one shown")
        shot(app, "changed")
    }
}
