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

        let board = app.staticTexts["Pets"]
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        board.tap()

        return app
    }

    func testConnectOpenBoardAndApproveAnAsset() throws {
        let app = try openPetsBoard()
        let reviews = app.buttons["reviewsButton"]
        XCTAssertTrue(reviews.waitForExistence(timeout: 15), "A board with review requests shows Reviews")
        reviews.tap()
        let request = app.staticTexts["Starter trees, round 1"]
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        request.tap()

        // Scroll to the apple image item and approve it.
        let apple = app.staticTexts["apple"]
        var tries = 0
        while !apple.isHittable && tries < 8 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(apple.exists)
        let approve = app.buttons.matching(NSPredicate(format: "label == 'Approve'")).allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(approve)
        approve?.tap()
        XCTAssertTrue(app.staticTexts["Approved"].waitForExistence(timeout: 10), "The decision shows after saving")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "review-approved"
        shot.lifetime = .keepAlways
        add(shot)
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
