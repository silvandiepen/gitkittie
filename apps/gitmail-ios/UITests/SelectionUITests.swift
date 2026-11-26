import Foundation
import XCTest

/// "See All Mail from…", Select All and Trash for many on a simulator against the local test
/// mail server (GKM-071): long-press a message, see everything from its sender, select all of
/// it, move it to Trash after one question, and go back with the From chip.
@MainActor
final class SelectionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testSeeAllMailFromASenderSelectAllAndTrash() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        let count = 60
        try await server.append((0..<count).map { "Deal \($0)" }, for: user, from: "Deals <deals@shop.example>")
        try await server.append(["Lunch on Friday", "The garden plan"], for: user)

        app = XCUIApplication()
        app.launchArguments = ["-uiTestFreshStore"]
        app.launchEnvironment["GKM_TEST_CA_PEM_BASE64"] = server.caPEM.base64EncodedString()
        app.launch()
        AddAccountForm(app: app, test: self).add(user, on: server)

        openMailbox("Inbox")
        let rows = app.descendants(matching: .any).matching(identifier: "messageRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 60))
        let deals = rows.containing(NSPredicate(format: "label CONTAINS 'From Deals'"))
        XCTAssertTrue(waitFor(timeout: 60) { deals.count > 3 }, "the inbox fills")

        // A tap still opens a conversation.
        deals.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["threadSubject"].waitForExistence(timeout: 15))
        goBackToList()

        // Long-press a deal: See All Mail from Deals.
        let deal = deals.firstMatch
        XCTAssertTrue(deal.waitForExistence(timeout: 10))
        deal.press(forDuration: 1.2)
        let seeAll = app.buttons["See All Mail from Deals"]
        XCTAssertTrue(seeAll.waitForExistence(timeout: 5))
        snapshot("selection-1-row-menu")
        seeAll.tap()
        let chip = app.buttons["senderChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "the From chip says what the list shows")
        XCTAssertTrue(waitFor { rows.containing(NSPredicate(format: "label CONTAINS 'From Bo'")).count == 0 }, "only their mail")

        // Select, Select All: every message from them, loaded or not.
        app.buttons["selectButton"].tap()
        let selectAll = app.buttons["selectAllButton"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        let selected = app.staticTexts["selectionCount"]
        XCTAssertTrue(waitFor { selected.exists && selected.label == "\(count) messages selected" }, "count: \(selected.label)")
        snapshot("selection-2-all-selected")

        // Trash asks once for many. The bottom bar is laid out again as the selection count
        // settles; a tap while it moves was lost once on CI (no dialog, GKM-086). Tap it still.
        let trash = app.buttons["selectionTrash"]
        var last = CGRect.null
        XCTAssertTrue(waitFor(timeout: 10) {
            let now = trash.frame
            defer { last = now }
            return trash.isHittable && now == last
        }, "the bottom bar's Trash settles")
        trash.tap()
        let confirm = app.buttons.matching(identifier: "confirmTrashButton").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        snapshot("selection-3-confirm")
        confirm.tap()
        XCTAssertTrue(waitFor(timeout: 10) { self.app.buttons["selectButton"].label == "Select" }, "Edit mode ends after the move")

        // The chip goes back to the Inbox, where only the other two are left.
        chip.tap()
        XCTAssertTrue(waitFor { !chip.exists })
        XCTAssertTrue(waitFor(timeout: 20) { rows.count == 2 }, "rows left: \(rows.count)")
        snapshot("selection-4-back")
    }

    // MARK: Helpers

    private func openMailbox(_ title: String) {
        // Mailbox rows are one element each, named mailbox.<title> (GKM-061).
        let row = app.descendants(matching: .any).matching(identifier: "mailbox.\(title)").firstMatch
        if !row.waitForExistence(timeout: 10) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
    }

    private func goBackToList() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    private func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func waitFor(timeout: TimeInterval = 30, _ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return condition()
    }
}
