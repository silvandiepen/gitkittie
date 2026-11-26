import Foundation
import XCTest

/// The everyday flow on a simulator against the local test mail server (GreenMail, started by
/// `swift/GitKittieMailProviders/scripts/test-mail-server.sh start`; the simulator reaches it on
/// loopback): add an account, read a conversation, swipe, search with a chip, write and send a
/// message to yourself and see it arrive. Screenshots of each main screen are attached to the
/// result (`scripts/test.sh` exports them).
@MainActor
final class MailFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testAddAccountReadSwipeSearchAndSend() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        try await server.append(["Lunch on Friday", "The garden plan", "Invoice for November"], for: user)

        app = XCUIApplication()
        app.launchArguments = ["-uiTestFreshStore"]
        app.launchEnvironment["GKM_TEST_CA_PEM_BASE64"] = server.caPEM.base64EncodedString()
        app.launch()

        // First run: no account. Add Account is in the empty list, and on iPad also in the
        // sidebar; both open the same sheet.
        let add = app.buttons.matching(identifier: "addAccountButton").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 20))
        snapshot("1-first-run")
        add.tap()

        // Other IMAP, pointed at the local server.
        let picker = app.segmentedControls["providerPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons["Other IMAP"].tap()
        type(user.address, into: app.textFields["addressField"])
        type(user.password, into: app.secureTextFields["passwordField"])
        replace(app.textFields["imapHostField"], with: "localhost")
        replace(app.textFields["imapPortField"], with: "3993")
        replace(app.textFields["smtpHostField"], with: "localhost")
        replace(app.textFields["smtpPortField"], with: "3465")
        chooseTLS()
        snapshot("2-add-account")
        app.buttons["addAccountConfirm"].tap()

        // Verified against both servers, saved, syncing: the sheet goes away.
        XCTAssertTrue(app.textFields["addressField"].waitForNonExistence(timeout: 45), "the account was not added: \(errorText())")

        // The account's inbox fills.
        openMailbox("Inbox")
        let rows = app.descendants(matching: .any).matching(identifier: "messageRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 45))
        XCTAssertTrue(waitFor { rows.count >= 3 }, "expected the three messages")
        snapshot("3-list")

        // Read one.
        let lunch = rows.containing(NSPredicate(format: "label CONTAINS 'Lunch on Friday'")).firstMatch
        lunch.tap()
        let subject = app.staticTexts["threadSubject"]
        XCTAssertTrue(subject.waitForExistence(timeout: 15))
        XCTAssertEqual(subject.label, "Lunch on Friday")
        snapshot("4-thread")
        goBackToList()

        // Swipe right: back to unread, through the action journal.
        let readRow = rows.containing(NSPredicate(format: "label CONTAINS 'Lunch on Friday'")).firstMatch
        XCTAssertTrue(readRow.waitForExistence(timeout: 10))
        XCTAssertFalse(readRow.label.hasPrefix("Unread"), "opening the conversation marks it read")
        readRow.swipeRight()
        // The swipe actions have their own identifiers: on iPad the open reader has Flag too.
        let unread = app.buttons["swipeReadUnread"]
        if unread.waitForExistence(timeout: 3) { unread.tap() }
        XCTAssertTrue(waitFor { rows.containing(NSPredicate(format: "label BEGINSWITH 'Unread' AND label CONTAINS 'Lunch on Friday'")).count == 1 })
        // Swipe left: flag it.
        readRow.swipeLeft()
        let flag = app.buttons["swipeFlag"]
        XCTAssertTrue(flag.waitForExistence(timeout: 5))
        flag.tap()
        XCTAssertTrue(waitFor { rows.containing(NSPredicate(format: "label CONTAINS 'Flagged' AND label CONTAINS 'Lunch on Friday'")).count == 1 })

        // Search with a chip.
        let search = app.searchFields.firstMatch
        revealSearch(search, pullingFrom: rows.element(boundBy: 0))
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("garden")
        XCTAssertTrue(waitFor { rows.count == 1 })
        XCTAssertTrue(app.descendants(matching: .any)["searchChips"].waitForExistence(timeout: 5))
        snapshot("5-search")
        endSearch(search)
        XCTAssertTrue(waitFor { rows.count >= 3 }, "ending the search shows the inbox again")

        // Write to yourself and send.
        let compose = app.buttons["composeButton"]
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
        compose.tap()
        let to = app.textFields["toField"]
        XCTAssertTrue(to.waitForExistence(timeout: 10))
        to.tap()
        to.typeText(user.address + ",")
        app.textFields["subjectField"].tap()
        app.textFields["subjectField"].typeText("Sent from the iPhone test")
        app.textViews["bodyField"].tap()
        app.textViews["bodyField"].typeText("Hello from the simulator.")
        snapshot("6-compose")
        app.buttons["sendButton"].tap()
        XCTAssertTrue(to.waitForNonExistence(timeout: 20), "the compose sheet did not close after Send")

        // The outbox sends it once; the inbox receives it.
        let sent = rows.containing(NSPredicate(format: "label CONTAINS 'Sent from the iPhone test'")).firstMatch
        XCTAssertTrue(waitFor(timeout: 90) {
            if !sent.exists { self.app.swipeDown(velocity: .slow) }
            return sent.exists
        }, "the sent message did not arrive in the inbox")

        // Settings: storage and what happens in the background, in words.
        openSettings()
        snapshot("7-settings")
    }

    // MARK: Helpers

    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
    }

    private func replace(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        if !field.isHittable { app.swipeUp() }
        // The fields are trailing-aligned: tap the right end so the cursor lands after the old
        // text (a plain tap can put it at the start on iPad, and the deletes then remove nothing).
        // Even then the cursor can land inside the text ("993" became "93993" on the iPhone
        // simulator, GKM-079), so when the deletes leave text behind, tap the end and delete
        // again. An empty field reports its placeholder as its value, and the host fields can
        // hold text equal to their placeholder, so only a change in value counts.
        let end = field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
        end.tap()
        var current = field.value as? String ?? ""
        for _ in 0..<3 {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
            let after = field.value as? String ?? ""
            if after.isEmpty || (after == field.placeholderValue && after != current) { break }
            current = after
            end.tap()
        }
        field.typeText(text)
    }

    /// On iPhone the search field is in the navigation bar's drawer, hidden until the list is
    /// pulled down at its top. Pull the way a person does: from the first row, slowly, holding
    /// at the end so the drawer settles open before the finger lifts. `app.swipeDown()` was a
    /// 0.2 s flick from the middle of the screen with no hold; there it started on the row just
    /// swiped and flagged, and on CI it once did not move the list at all (GKM-079).
    private func revealSearch(_ search: XCUIElement, pullingFrom row: XCUIElement) {
        guard !search.exists else { return }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 240)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    /// Leaves search the way each system offers it: iOS 26 on iPhone has a round Close button
    /// beside the field, older iPhone systems have Cancel, iPad has only the field's clear
    /// button. The keyboard has to go too, or it covers the bottom bar's Compose.
    private func endSearch(_ search: XCUIElement) {
        let close = app.buttons["Close"].firstMatch
        let cancel = app.buttons["Cancel"].firstMatch
        if close.exists {
            close.tap()
        } else if cancel.exists {
            cancel.tap()
        } else {
            search.buttons["Clear text"].tap()
        }
        if app.keyboards.firstMatch.exists {
            app.swipeDown()
        }
        XCTAssertTrue(waitFor(timeout: 5) { !self.app.keyboards.firstMatch.exists }, "the keyboard stays up after search")
    }

    private func chooseTLS() {
        let picker = app.buttons["smtpSecurityPicker"]
        if !picker.isHittable { app.swipeUp() }
        picker.tap()
        let tls = app.buttons["TLS"]
        XCTAssertTrue(tls.waitForExistence(timeout: 5))
        tls.tap()
    }

    private func errorText() -> String {
        let error = app.descendants(matching: .any).matching(identifier: "accountError").firstMatch
        return error.exists ? error.label : "no error shown"
    }

    /// On iPhone the mailboxes are a pushed column; on iPad they are on screen.
    private func openMailbox(_ title: String) {
        let row = app.staticTexts[title].firstMatch
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

    private func openSettings() {
        let settings = app.buttons["settingsButton"]
        if !settings.exists { app.navigationBars.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.staticTexts["When Mail Isn’t Open"].waitForExistence(timeout: 5)
                      || app.staticTexts["WHEN MAIL ISN’T OPEN"].waitForExistence(timeout: 2))
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
