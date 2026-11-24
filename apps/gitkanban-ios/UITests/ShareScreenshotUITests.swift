import XCTest

/// End-to-end: share an image from Photos to the "Tasks" share extension, mark it up and
/// add it as a new task, then share again and add it to that task. The extension reads its
/// boards from the App Group it shares with the app, so a board has to be there first:
/// run `scripts/seed-share-fixture.sh <simulator-udid>` (it prints the folder the task and
/// its attachments land in). With no board, the extension says so and this test skips.
final class ShareScreenshotUITests: XCTestCase {
    private let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Attach the current screen to the test result, to look at afterwards.
    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Open Photos, pick the first picture and share it to Tasks. Leaves the form open.
    private func shareFirstPhotoToTasks() throws {
        photos.launch()
        for label in ["Continue", "Not Now"] {
            let button = photos.buttons[label]
            if button.waitForExistence(timeout: 3) { button.tap() }
        }
        // The library grid's cells carry no stable identifier, so tap where the first one is.
        XCTAssertTrue(photos.staticTexts["Library"].firstMatch.waitForExistence(timeout: 15), "Photos opens on the library")
        photos.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.22)).tap()
        let share = photos.buttons["Share"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.tap()

        let tasks = photos.cells.matching(NSPredicate(format: "label == 'Tasks'")).firstMatch
        XCTAssertTrue(tasks.waitForExistence(timeout: 15), "Tasks is a share target for images.\n\(photos.debugDescription)")
        tasks.tap()

        if !photos.buttons["shareProjectPicker"].firstMatch.waitForExistence(timeout: 20) {
            if photos.staticTexts["No boards yet"].exists { throw XCTSkip("No board is added in the app") }
            XCTFail("The share sheet shows the task form.\n\(photos.debugDescription)")
        }
    }

    /// The board is chosen in a panel: the form names the board, with its repository small
    /// under it; the panel lists the boards under their repositories and ticks the chosen one.
    func testChooseTheBoardInAPanel() throws {
        try shareFirstPhotoToTasks()
        keepScreenshot("form")
        photos.buttons["shareProjectPicker"].firstMatch.tap()
        let panel = photos.navigationBars["Board"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "The board panel opens.\n\(photos.debugDescription)")
        keepScreenshot("board-panel")
        panel.buttons["Cancel"].tap()
        XCTAssertTrue(photos.buttons["shareProjectPicker"].firstMatch.waitForExistence(timeout: 10), "Cancel goes back to the form")
    }

    /// The same sheet is also an action in the share sheet's list, where "Save to Files" lives.
    func testAddToTasksActionOpensTheSheet() throws {
        photos.launch()
        XCTAssertTrue(photos.staticTexts["Library"].firstMatch.waitForExistence(timeout: 15))
        photos.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.22)).tap()
        let share = photos.buttons["Share"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        share.tap()
        let action = photos.cells.matching(NSPredicate(format: "label == 'Add to Tasks'")).firstMatch
        var swipes = 0
        while !(action.exists && action.isHittable) && swipes < 6 { photos.swipeUp(); swipes += 1 }
        XCTAssertTrue(action.exists, "Add to Tasks is in the action list.\n\(photos.debugDescription)")
        keepScreenshot("action-list")
        action.tap()
        let form = photos.buttons["shareProjectPicker"].firstMatch
        if !form.waitForExistence(timeout: 20) {
            if photos.staticTexts["No boards yet"].exists { throw XCTSkip("No board is added in the app") }
            XCTFail("The action opens the task form.\n\(photos.debugDescription)")
        }
    }

    private func tapAddAndWaitForTheSheetToClose() {
        let add = photos.buttons["shareAddButton"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: add)], timeout: 20)
        add.tap()
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: add)], timeout: 30)
    }

    func testShareAnAnnotatedPhotoAsANewTaskThenAddToIt() throws {
        // 1. A new task, with a part of the image marked and commented in one tap.
        try shareFirstPhotoToTasks()
        photos.buttons["annotateButton"].firstMatch.tap()
        let canvas = photos.otherElements["annotationCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10), "The annotation editor opens.\n\(photos.debugDescription)")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
        let chip = photos.buttons["Misaligned"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "Quick comments are offered for the new box")
        keepScreenshot("annotate")
        chip.tap()
        XCTAssertTrue(photos.staticTexts["Misaligned"].waitForExistence(timeout: 5), "The comment is listed")
        photos.buttons["Done"].firstMatch.tap()

        let title = photos.textFields["shareTitleField"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText("Shared from Photos")
        keepScreenshot("share-sheet")
        tapAddAndWaitForTheSheetToClose()

        // 2. Share again, this time into the task that now exists.
        try shareFirstPhotoToTasks()
        photos.buttons["Existing task"].firstMatch.tap()
        let chooser = photos.buttons["shareExistingTask"].firstMatch
        XCTAssertTrue(chooser.waitForExistence(timeout: 10))
        chooser.tap()
        let task = photos.staticTexts["Shared from Photos"].firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 10), "The board's tasks are listed.\n\(photos.debugDescription)")
        task.tap()
        keepScreenshot("existing-task")
        tapAddAndWaitForTheSheetToClose()
    }
}
