import XCTest

/// End-to-end: find a GitKanban folder server on the network (Bonjour), open a board, and
/// decide on a review item. Needs a folder server running on the host with the review fixture,
/// announcing itself under the test name and pointing at its loopback address:
///   GKS_ROOT=<fixture> GKS_PORT=4418 GKS_NAME="GitKanban UI test" \
///   GKS_PUBLIC_URL=http://127.0.0.1:4418 node apps/gitkanban-server/dist/index.js
/// The fixture has a `Tasks/Pets` board and `Pets/review/PETS-1-trees/review.md`.
/// Skips when no server answers, so the suite still runs on a bare machine.
final class FolderReviewUITests: XCTestCase {
    private let serverURL = ProcessInfo.processInfo.environment["GK_FOLDER_SERVER"] ?? "http://127.0.0.1:4418"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func serverIsUp() -> Bool {
        guard let url = URL(string: "\(serverURL)/api/health") else { return false }
        let done = expectation(description: "health")
        var ok = false
        URLSession.shared.dataTask(with: url) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return ok
    }

    /// Launch fresh, add the announced server without typing, and open the Pets board.
    private func openPetsBoard() throws -> XCUIApplication {
        let app = try addBoards()
        let board = app.staticTexts["Pets"]
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        board.tap()
        return app
    }

    /// Launch fresh and add the announced server's boards; ends on the home screen.
    private func addBoards() throws -> XCUIApplication {
        guard serverIsUp() else { throw XCTSkip("No folder server at \(serverURL)") }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-gitkanban.connection", "", "-gitkanban.addedReposV2", "", "-gitkanban.activeRepo", ""]
        app.launch()

        XCTAssertTrue(app.buttons["Open the demo board"].waitForExistence(timeout: 10))
        // No typing: the server shows up by itself.
        let found = app.buttons.matching(NSPredicate(format: "identifier == 'discoveredServer' AND label CONTAINS 'GitKanban UI test'")).firstMatch
        var scrolls = 0
        while !(found.exists && found.isHittable) && scrolls < 6 {
            if !found.waitForExistence(timeout: 3) { app.swipeUp() }
            scrolls += 1
        }
        if !found.waitForExistence(timeout: 10) {
            XCTFail("The announced server is listed on the connect screen.\n\(app.debugDescription)")
        }
        found.tap()

        let browse = app.buttons["Browse boards…"]
        XCTAssertTrue(browse.waitForExistence(timeout: 15), "The folder entry appears on the home screen")
        browse.tap()
        let tasks = app.staticTexts["Tasks"]
        XCTAssertTrue(tasks.waitForExistence(timeout: 10))
        tasks.tap()
        let selectAll = app.buttons["Select All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 10))
        selectAll.tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Pets"].waitForExistence(timeout: 10))
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The home screen says reviews are waiting on the boards. A request opens as slides
    /// showing what has no answer yet; leaving with one unanswered asks first; a marked-up
    /// image goes along as a comment; and "Review All" walks through the requests still
    /// open, across boards, where a pick-one choice says plainly which option was picked.
    /// The fixture has two boards with one open request each.
    func testHomeShowsReviewsAndReviewAllWalksThroughThem() throws {
        let app = try addBoards()
        let row = app.buttons["homeReviewsRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "The home screen shows a Reviews row.\n\(app.debugDescription)")
        XCTAssertTrue(row.label.contains("waiting"), "It says how much is waiting: \(row.label)")
        // The first reviews found are when the app asks to send notifications.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        shot(app, "home-reviews")
        row.tap()

        let trees = app.staticTexts["Starter trees, round 1"]
        XCTAssertTrue(trees.waitForExistence(timeout: 10), "Requests of the first board are listed")
        XCTAssertTrue(app.staticTexts["Collar colours"].exists, "and those of the second, kept inside its board")
        shot(app, "reviews-inbox")

        // One request, as slides.
        trees.tap()
        let answered = app.staticTexts["reviewAnsweredCount"]
        XCTAssertTrue(answered.waitForExistence(timeout: 10))
        XCTAssertEqual(answered.label, "0 of 2 answered")

        // The image opens full screen and can be closed again: swiped away, or with the cross.
        let enlarge = app.descendants(matching: .any)["reviewAssetImage"].firstMatch
        XCTAssertTrue(enlarge.waitForExistence(timeout: 10))
        enlarge.tap()
        let viewer = app.images["reviewImageViewer"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 10), "Tapping the image enlarges it.\n\(app.debugDescription)")
        viewer.swipeDown()
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: viewer)], timeout: 10)
        enlarge.tap()
        XCTAssertTrue(app.buttons["reviewImageClose"].waitForExistence(timeout: 10))
        app.buttons["reviewImageClose"].tap()
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: viewer)], timeout: 10)

        // Mark up the first image: the marks arrive as a comment.
        let annotate = app.buttons["reviewAnnotateButton"].firstMatch
        XCTAssertTrue(annotate.waitForExistence(timeout: 10))
        annotate.tap()
        let canvas = app.otherElements["annotationCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
        let chip = app.buttons["Cut off"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1. Cut off"].waitForExistence(timeout: 15), "The marks show as a comment.\n\(app.debugDescription)")

        // Answer the first; the deck moves on to the one without an answer.
        app.buttons.matching(NSPredicate(format: "label == 'Approve'")).allElementsBoundByIndex.first { $0.isHittable }?.tap()
        wait(for: [expectation(for: NSPredicate(format: "label == '1 of 2 answered'"), evaluatedWith: answered)], timeout: 10)
        shot(app, "review-slide")

        // Leaving with one unanswered asks first, and can take you to it.
        app.buttons["reviewBackButton"].tap()
        let goOn = app.buttons["Continue Reviewing"]
        XCTAssertTrue(goOn.waitForExistence(timeout: 10), "Closing with an unanswered item asks.\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["1 item has no answer yet"].exists)
        shot(app, "review-close-check")
        goOn.tap()
        let reject = app.buttons.matching(NSPredicate(format: "label == 'Reject'")).allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(reject)
        reject?.tap()
        wait(for: [expectation(for: NSPredicate(format: "label == '2 of 2 answered'"), evaluatedWith: answered)], timeout: 10)
        app.buttons["reviewBackButton"].tap()

        // Everything answered: no question on the way out, and the request is off the list.
        let all = app.buttons["reviewAllButton"]
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        XCTAssertFalse(trees.exists, "An answered request is no longer waiting")
        all.tap()
        XCTAssertTrue(app.staticTexts["Request 1 of 1"].waitForExistence(timeout: 10))
        let pick = app.buttons.matching(NSPredicate(format: "label == 'Pick This'")).allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(pick, "A pick-one group offers Pick This.\n\(app.debugDescription)")
        pick?.tap()
        XCTAssertTrue(app.staticTexts["Picked: blue"].waitForExistence(timeout: 10), "The choice is stated")
        shot(app, "review-picked")
        app.buttons["reviewNextButton"].tap()
        XCTAssertTrue(app.staticTexts["Nothing is waiting for you"].waitForExistence(timeout: 10), "Finishing returns to the list")
    }

    func testProgressListShowsStagesAndMarksRead() throws {
        let app = try openPetsBoard()
        let toggle = app.buttons["viewModeButton"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        if !app.staticTexts["Working on"].exists { toggle.tap() }
        XCTAssertTrue(app.staticTexts["Working on"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Up next"].exists)
        XCTAssertTrue(app.staticTexts["Checked off"].exists)
        XCTAssertTrue(app.staticTexts["Pet feeding animation"].exists)
        let list = XCTAttachment(screenshot: app.screenshot())
        list.name = "progress-list"
        list.lifetime = .keepAlways
        add(list)

        app.staticTexts["Fix pet name clipping on small phones"].tap()
        let markRead = app.buttons["markRead"]
        XCTAssertTrue(markRead.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["attachmentImage"].waitForExistence(timeout: 10), "Screenshots show in the card")
        let card = XCTAttachment(screenshot: app.screenshot())
        card.name = "card-unread-with-screenshots"
        card.lifetime = .keepAlways
        add(card)
        markRead.tap()
        XCTAssertTrue(app.buttons["Mark Unread"].waitForExistence(timeout: 10), "The card shows it was read")
        let read = XCTAttachment(screenshot: app.screenshot())
        read.name = "card-read"
        read.lifetime = .keepAlways
        add(read)
    }
}
