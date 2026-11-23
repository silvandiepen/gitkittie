import XCTest

/// In the app: a new task with an image from the photo library, marked up before it is
/// created. Runs on the offline demo board. The title is left empty on purpose: it has to
/// be written from the mark.
final class NewTaskImageUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testNewTaskFromAnImageWithAMarkGetsATitle() throws {
        let app = XCUIApplication()
        app.launchEnvironment["GITKANBAN_DEMO"] = "1"
        app.launch()

        let newTask = app.buttons["newTaskButton"].firstMatch
        XCTAssertTrue(newTask.waitForExistence(timeout: 15))
        newTask.tap()
        let addImages = app.buttons["newTaskAddImages"].firstMatch
        var swipes = 0
        while !(addImages.exists && addImages.isHittable) && swipes < 4 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(addImages.waitForExistence(timeout: 10))
        addImages.tap()

        // The system photo picker runs out of process and exposes no stable identifiers:
        // tap the first picture and the confirm checkmark by position.
        XCTAssertTrue(app.staticTexts["Select Photos"].firstMatch.waitForExistence(timeout: 15), "The photo picker opens.\n\(app.debugDescription)")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.44)).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.155)).tap()

        let markUp = app.buttons["Mark up image"].firstMatch
        XCTAssertTrue(markUp.waitForExistence(timeout: 15), "The picked image shows in the sheet.\n\(app.debugDescription)")
        markUp.tap()
        let canvas = app.otherElements["annotationCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
        let chip = app.buttons["Cut off"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()
        app.buttons["Done"].firstMatch.tap()

        // Create without typing a title; the sheet closes at once.
        let create = app.buttons["Create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: create)], timeout: 30)
        // Give an automatic draft the chance to finish, so the title is the drafted one.
        let drafting = app.staticTexts["Writing a title and description"]
        if drafting.exists { wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: drafting)], timeout: 40) }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "new-task-with-image"
        attachment.lifetime = .keepAlways
        add(attachment)
        create.tap()
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: create)], timeout: 10)

        // A fifth card is on the first lane (the demo starts with four).
        let count = app.staticTexts["5"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 15), "The new task is on the board.\n\(app.debugDescription)")
    }
}
