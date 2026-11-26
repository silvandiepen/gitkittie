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

        launch(server)

        // First run: no account. Add Account is in the empty list, and on iPad also in the
        // sidebar; both open the same sheet.
        let add = app.buttons.matching(identifier: "addAccountButton").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 20))
        snapshot("1-first-run")
        audit("first run")
        add.tap()

        fillInAccount(user)
        hideKeyboard()
        snapshot("2-add-account")
        audit("add account")
        app.buttons["addAccountConfirm"].tap()

        // Verified against both servers, saved, syncing: the sheet goes away.
        waitForAccountAdded()

        // The account's inbox fills.
        openMailbox("Inbox")
        let rows = app.descendants(matching: .any).matching(identifier: "messageRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 45))
        XCTAssertTrue(waitFor { rows.count >= 3 }, "expected the three messages")
        snapshot("3-list")
        audit("list")

        // Read one.
        let lunch = rows.containing(NSPredicate(format: "label CONTAINS 'Lunch on Friday'")).firstMatch
        lunch.tap()
        let subject = app.staticTexts["threadSubject"]
        XCTAssertTrue(subject.waitForExistence(timeout: 15))
        XCTAssertEqual(subject.label, "Lunch on Friday")
        snapshot("4-thread")
        audit("thread")
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
        if !search.exists { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("garden")
        XCTAssertTrue(waitFor { rows.count == 1 })
        XCTAssertTrue(app.descendants(matching: .any)["searchChips"].waitForExistence(timeout: 5))
        snapshot("5-search")
        audit("search")
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
        audit("compose")
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
        audit("settings")
        app.buttons["Done"].firstMatch.tap()

        // The mailboxes, with the account and its folders.
        showMailboxes()
        snapshot("8-mailboxes")
        audit("mailboxes")

        assertNoAccessibilityIssues()
    }

    /// The main screens at the largest accessibility text size (GKM-061): the audits include
    /// Dynamic Type and clipped text, so a fixed height or a one-line limit that hides text
    /// fails here.
    func testMainScreensAtLargestTextSize() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        try await server.append(["A subject long enough to need more than one line at this size"], for: user)

        // One store for the three launches below.
        let store = ["-uiTestStoreName", "large-\(UUID().uuidString)"]
        let largest = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

        // First run and the account form at the largest size.
        launch(server, arguments: store + largest)
        let add = app.buttons.matching(identifier: "addAccountButton").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 20))
        snapshot("large-1-first-run")
        audit("large: first run")
        add.tap()
        XCTAssertTrue(app.textFields["addressField"].waitForExistence(timeout: 5))
        snapshot("large-2-add-account")
        audit("large: add account")
        app.terminate()

        // The account is added at the default size: at this one iOS's Save Password offer is
        // taller than the screen and its Not Now can't be reached, so it would hold the sheet.
        launch(server, arguments: store)
        let addAgain = app.buttons.matching(identifier: "addAccountButton").firstMatch
        XCTAssertTrue(addAgain.waitForExistence(timeout: 20))
        addAgain.tap()
        fillInAccount(user)
        app.buttons["addAccountConfirm"].tap()
        waitForAccountAdded()
        app.terminate()

        // Everything else at the largest size, with the account.
        launch(server, arguments: store + largest)

        openMailbox("Inbox")
        let rows = app.descendants(matching: .any).matching(identifier: "messageRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 45))
        snapshot("large-3-list")
        audit("large: list")

        rows.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["threadSubject"].waitForExistence(timeout: 15))
        snapshot("large-4-thread")
        audit("large: thread")
        goBackToList()

        let compose = app.buttons["composeButton"]
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
        compose.tap()
        let to = app.textFields["toField"]
        XCTAssertTrue(to.waitForExistence(timeout: 10))
        to.typeText(user.address + ",")
        snapshot("large-5-compose")
        audit("large: compose")
        app.buttons["Cancel"].firstMatch.tap()
        let save = app.buttons["Save Draft"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(to.waitForNonExistence(timeout: 10))

        openSettings()
        snapshot("large-6-settings")
        audit("large: settings")
        app.buttons["Done"].firstMatch.tap()

        showMailboxes()
        snapshot("large-7-mailboxes")
        audit("large: mailboxes")

        assertNoAccessibilityIssues()
    }

    // MARK: Accessibility

    /// What the audits found that is not excluded, by screen; the test fails with all of it at
    /// the end, so one run lists every issue.
    private var auditFindings: [String] = []

    /// Runs every audit type on what is on screen (GKM-061). Nothing is excluded wholesale:
    /// `AccessibilityAuditPolicy` names each system control that is skipped, and why.
    private func audit(_ screen: String) {
        var found: [AuditFinding] = []
        do {
            // The handler only copies the issue; the app is looked at after the audit.
            try app.performAccessibilityAudit(for: .all) { issue in
                found.append(AuditFinding(issue))
                return true
            }
        } catch {
            auditFindings.append("[\(screen)] the audit could not run: \(error)")
        }
        for finding in found {
            if let reason = AccessibilityAuditPolicy.skipReason(finding, in: app) {
                print("audit [\(screen)] skipped (\(reason)): \(finding.description)")
            } else {
                auditFindings.append("[\(screen)] \(finding.description)")
            }
        }
    }

    private func assertNoAccessibilityIssues() {
        XCTAssertTrue(auditFindings.isEmpty, "accessibility audit:\n" + auditFindings.joined(separator: "\n"))
    }

    // MARK: Helpers

    private func launch(_ server: LocalMailServer, arguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-uiTestFreshStore"] + arguments
        app.launchEnvironment["GKM_TEST_CA_PEM_BASE64"] = server.caPEM.base64EncodedString()
        app.launch()
    }

    /// Verified against both servers, saved, syncing: the sheet goes away. iOS may offer to
    /// save the password meanwhile, over the sheet; the test declines.
    private func waitForAccountAdded() {
        let added = waitFor(timeout: 60) {
            self.declineSavePassword(wait: 0.5)
            return !self.app.textFields["addressField"].exists
        }
        if !added { snapshot("account-not-added") }
        XCTAssertTrue(added, "the account was not added: \(errorText())")
    }

    private func hasKeyboardFocus(_ field: XCUIElement) -> Bool {
        (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    private func hideKeyboard() {
        let done = app.buttons["keyboardDone"]
        if app.keyboards.firstMatch.exists, done.exists, done.isHittable { done.tap() }
    }

    /// iOS may offer to save the test password in Passwords; the test never does.
    private func declineSavePassword(wait: TimeInterval = 3) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for owner in [app!, springboard] {
            let notNow = owner.buttons["Not Now"]
            guard notNow.waitForExistence(timeout: wait) else { continue }
            // At the largest text sizes the offer is taller than the screen and Not Now starts
            // below it: scroll the offer up first.
            for _ in 0..<3 where !notNow.isHittable { owner.staticTexts["Save Password?"].firstMatch.swipeUp() }
            notNow.tap()
            return
        }
    }

    /// Other IMAP, pointed at the local server.
    private func fillInAccount(_ user: LocalMailServer.User) {
        let picker = app.segmentedControls["providerPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons["Other IMAP"].tap()
        type(user.address, into: app.textFields["addressField"])
        type(user.password, into: app.secureTextFields["passwordField"])
        // When the password field scrolls away (the large sizes), iOS may offer to save it.
        for (field, value) in [("imapHostField", "localhost"), ("imapPortField", "3993"),
                               ("smtpHostField", "localhost"), ("smtpPortField", "3465")] {
            declineSavePassword(wait: 1)
            replace(app.textFields[field], with: value)
        }
        declineSavePassword(wait: 1)
        chooseTLS()
    }

    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // At the largest text sizes the keyboard of the field before can cover this one.
        hideKeyboard()
        field.tap()
        field.typeText(text)
    }

    private func replace(_ field: XCUIElement, with text: String) {
        for _ in 0..<4 where !field.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // At the largest text sizes the keyboard of the field before, or the sheet's bar, can
        // cover this one: put the keyboard away (the number pad has no Return), tap, and try
        // again from a new scroll position until the field has the keyboard.
        for _ in 0..<4 {
            hideKeyboard()
            if !field.isHittable { app.swipeUp(velocity: .slow) }
            if field.frame.height > 60 {
                // Wrapped: the text sits at the bottom right. Focus first, then tap its end.
                field.tap()
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.85)).tap()
            } else {
                // The fields are trailing-aligned: tap the right end so the cursor lands after
                // the old text (a plain tap can put it at the start on iPad, and the deletes then
                // remove nothing).
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            }
            if hasKeyboardFocus(field) { break }
            app.swipeDown(velocity: .slow)
        }
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        field.typeText(text)
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
        hideKeyboard()
        let picker = app.buttons["smtpSecurityPicker"]
        for _ in 0..<6 where !(picker.exists && picker.isHittable) { app.swipeUp() }
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
        let row = app.descendants(matching: .any).matching(identifier: "mailbox.\(title)").firstMatch
        if !row.waitForExistence(timeout: 10) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        // At the largest text sizes the account's folders are further down the list.
        for _ in 0..<6 where !(row.waitForExistence(timeout: 3) && row.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
    }

    private func goBackToList() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// On iPhone the mailboxes are the first column of the stack; on iPad they are on screen.
    private func showMailboxes() {
        let focused = app.descendants(matching: .any)["mailbox.Focused"]
        if !focused.waitForExistence(timeout: 3) { app.navigationBars.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(focused.waitForExistence(timeout: 10))
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
