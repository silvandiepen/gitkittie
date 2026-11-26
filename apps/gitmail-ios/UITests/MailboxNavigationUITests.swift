import Foundation
import XCTest

/// Choosing a mailbox in the sidebar, against the local test mail server (GKM-080). On iPhone,
/// going back to Mailboxes and choosing the mailbox you came from opens it again, every time;
/// on iPad, where the columns are side by side, the chosen mailbox stays highlighted.
@MainActor
final class MailboxNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testChoosingTheSameMailboxAgainOpensIt() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        try await server.append(["Lunch on Friday", "The garden plan"], for: user)

        app = XCUIApplication()
        app.launchArguments = ["-uiTestFreshStore"]
        app.launchEnvironment["GKM_TEST_CA_PEM_BASE64"] = server.caPEM.base64EncodedString()
        app.launch()
        addAccount(user)

        let account = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'mailbox.All of '")).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 20) || showMailboxes() && account.waitForExistence(timeout: 20))
        // The row says "All of <name>"; the list it opens is titled with the name.
        let accountTitle = String(account.label.dropFirst("All of ".count))
        let accountIdentifier = account.identifier

        if UIDevice.current.userInterfaceIdiom == .phone {
            // Inbox, back, Inbox: the list opens again, every time.
            for attempt in 1...3 {
                choose("mailbox.Inbox", opens: "Inbox", attempt: attempt)
                let rows = app.descendants(matching: .any).matching(identifier: "messageRow")
                XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 45), "Inbox shows its mail")
                snapshot("navigation-inbox-\(attempt)")
                XCTAssertTrue(showMailboxes())
            }
            // Back on Mailboxes, nothing looks chosen: the row you came from is a plain row.
            XCTAssertFalse(row("mailbox.Inbox").isSelected, "the Inbox row stays selected after going back")
            // The same for the other kinds of row: a category, Drafts, and the whole account.
            for (identifier, title) in [("mailbox.Focused", "Focused"), ("mailbox.Drafts", "Drafts"),
                                        (accountIdentifier, accountTitle)] {
                for attempt in 1...2 {
                    choose(identifier, opens: title, attempt: attempt)
                    XCTAssertTrue(showMailboxes())
                }
            }
        } else {
            // iPad: the chosen mailbox stays highlighted beside its list, also when chosen again.
            for attempt in 1...2 {
                choose("mailbox.Inbox", opens: "Inbox", attempt: attempt)
                XCTAssertTrue(showMailboxes())
                XCTAssertTrue(waitFor(timeout: 5) { self.row("mailbox.Inbox").isSelected }, "the Inbox row is highlighted")
            }
            // (Opening a conversation here is left out: on iPad portrait a row tap after choosing
            // a mailbox doesn't open it yet, on main too; GKM-064 owns that.)
            let rows = app.descendants(matching: .any).matching(identifier: "messageRow")
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 45), "Inbox shows its mail")
            XCTAssertTrue(showMailboxes())
            XCTAssertTrue(row("mailbox.Inbox").isSelected, "the Inbox row stays highlighted beside its list")
            choose("mailbox.Drafts", opens: "Drafts", attempt: 1)
            XCTAssertTrue(showMailboxes())
            XCTAssertTrue(waitFor(timeout: 5) { self.row("mailbox.Drafts").isSelected && !self.row("mailbox.Inbox").isSelected })
            snapshot("navigation-ipad")
        }
    }

    // MARK: Helpers

    private func row(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Taps a sidebar row and waits for the list it opens, by its title.
    private func choose(_ identifier: String, opens title: String, attempt: Int) {
        let row = row(identifier)
        if !(row.exists && row.isHittable) { showMailboxes() }
        for _ in 0..<6 where !(row.waitForExistence(timeout: 3) && row.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.isHittable, "\(identifier) can be tapped")
        row.tap()
        let opened = waitFor(timeout: 10) {
            self.app.navigationBars[title].exists
                && (UIDevice.current.userInterfaceIdiom == .pad || !self.app.navigationBars["Mailboxes"].exists)
        }
        if !opened { snapshot("navigation-not-opened-\(title)-\(attempt)") }
        XCTAssertTrue(opened, "choosing \(title) (time \(attempt)) did not open its list")
    }

    /// On iPhone the mailboxes are the first column of the stack (Back); on iPad in portrait
    /// they slide over the list and away again once one is chosen (the sidebar button).
    @discardableResult
    private func showMailboxes() -> Bool {
        let focused = row("mailbox.Focused")
        if !(focused.exists && focused.isHittable) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        return app.navigationBars["Mailboxes"].waitForExistence(timeout: 10)
            && waitFor(timeout: 5) { focused.isHittable }
    }

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
        hideKeyboard()
        let security = app.buttons["smtpSecurityPicker"]
        for _ in 0..<6 where !(security.exists && security.isHittable) { app.swipeUp() }
        security.tap()
        let tls = app.buttons["TLS"]
        XCTAssertTrue(tls.waitForExistence(timeout: 5))
        tls.tap()
        app.buttons["addAccountConfirm"].tap()
        let added = waitFor(timeout: 60) {
            self.declineSavePassword()
            return !self.app.textFields["addressField"].exists
        }
        XCTAssertTrue(added, "the account was not added")
    }

    /// iOS may offer to save the test password in Passwords; the test never does.
    private func declineSavePassword() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for owner in [app!, springboard] where owner.buttons["Not Now"].exists {
            owner.buttons["Not Now"].tap()
            return
        }
    }

    private func hideKeyboard() {
        let done = app.buttons["keyboardDone"]
        if app.keyboards.firstMatch.exists, done.exists, done.isHittable { done.tap() }
    }

    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        hideKeyboard()
        field.tap()
        field.typeText(text)
    }

    private func replace(_ field: XCUIElement, with text: String) {
        // On iPad the server fields start below the sheet's fold: scroll until the field is there.
        for _ in 0..<4 where !field.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // The number pad has no Return: put it away (Done above it), or it covers the next field.
        for _ in 0..<4 {
            hideKeyboard()
            if !field.isHittable { app.swipeUp(velocity: .slow) }
            // Trailing-aligned: tap the right end so the cursor lands after the old text.
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            if (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false { break }
            app.swipeDown(velocity: .slow)
        }
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        field.typeText(text)
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
