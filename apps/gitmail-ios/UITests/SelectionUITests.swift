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
        addAccount(user)

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

        // Trash asks once for many.
        app.buttons["selectionTrash"].tap()
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

    private func addAccount(_ user: LocalMailServer.User) {
        let add = app.buttons.matching(identifier: "addAccountButton").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 20))
        add.tap()
        let picker = app.segmentedControls["providerPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons["Other IMAP"].tap()
        type(user.address, into: app.textFields["addressField"])
        type(user.password, into: app.secureTextFields["passwordField"])
        replace(app.textFields["imapHostField"], with: "localhost")
        replace(app.textFields["imapPortField"], with: "3993")
        replace(app.textFields["smtpHostField"], with: "localhost")
        replace(app.textFields["smtpPortField"], with: "3465")
        let done = app.buttons["keyboardDone"]
        if app.keyboards.firstMatch.exists, done.exists, done.isHittable { done.tap() }
        let security = app.buttons["smtpSecurityPicker"]
        if !security.isHittable { app.swipeUp() }
        security.tap()
        let tls = app.buttons["TLS"]
        XCTAssertTrue(tls.waitForExistence(timeout: 5))
        tls.tap()
        app.buttons["addAccountConfirm"].tap()
        XCTAssertTrue(app.textFields["addressField"].waitForNonExistence(timeout: 45), "the account was not added")
    }

    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
    }

    private func replace(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // The number pad has no Return: put it away (Done above it), or it covers the next field.
        let done = app.buttons["keyboardDone"]
        if app.keyboards.firstMatch.exists, done.exists, done.isHittable { done.tap() }
        if !field.isHittable { app.swipeUp() }
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        field.typeText(text)
    }

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
