import Foundation
import XCTest

/// The Add Account sheet, filled in the one way every UI test adds its account (GKM-086): Other
/// IMAP, pointed at the local test server, with TLS for sending.
///
/// The server fields come prefilled (the ports with 993 and 587), so each one is replaced and then
/// read back. A tap that leaves the cursor before the old text makes the deletes remove nothing,
/// and `3993` typed there turns 993 into `3993993`; the check then fails on the server's port. So
/// a field is only done when it reads exactly what was typed.
@MainActor
struct AddAccountForm {
    let app: XCUIApplication
    /// Where the screenshot of a failure goes.
    let test: XCTestCase

    /// From the Add Account button (the empty list's, or on iPad the sidebar's) to the account
    /// saved and the sheet gone.
    func add(_ user: LocalMailServer.User, on server: LocalMailServer) {
        let add = app.buttons.matching(identifier: "addAccountButton").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 20), "Add Account is offered")
        add.tap()
        fillIn(user, on: server)
        confirm()
    }

    /// Other IMAP, pointed at the local server; the sheet is left open.
    func fillIn(_ user: LocalMailServer.User, on server: LocalMailServer) {
        let picker = app.segmentedControls["providerPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons["Other IMAP"].tap()
        type(user.address, into: app.textFields["addressField"])
        type(user.password, into: app.secureTextFields["passwordField"])
        // When the password field scrolls away, iOS may offer to save it.
        for (field, value) in [("imapHostField", "localhost"), ("imapPortField", String(server.imapsPort)),
                               ("smtpHostField", "localhost"), ("smtpPortField", String(server.smtpsPort))] {
            declineSavePassword(wait: 1)
            replace(app.textFields[field], with: value)
        }
        declineSavePassword(wait: 1)
        chooseTLS()
    }

    /// Add: verified against both servers, saved, syncing, and the sheet goes away. iOS may
    /// offer to save the password meanwhile, over the sheet, where it holds the sheet open until
    /// it is answered; the test declines.
    func confirm() {
        hideKeyboard()
        app.buttons["addAccountConfirm"].tap()
        let added = waitFor(timeout: 60) {
            declineSavePassword(wait: 0.5)
            return !app.textFields["addressField"].exists
        }
        if !added {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "\(UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")-account-not-added"
            shot.lifetime = .keepAlways
            test.add(shot)
        }
        XCTAssertTrue(added, "the account was not added: \(errorText())")
    }

    /// iOS may offer to save the test password in Passwords; the test never does.
    func declineSavePassword(wait: TimeInterval = 3) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for owner in [app, springboard] {
            let notNow = owner.buttons["Not Now"]
            guard notNow.waitForExistence(timeout: wait) else { continue }
            // At the largest text sizes the offer is taller than the screen and Not Now starts
            // below it: scroll the offer up first.
            for _ in 0..<3 where !notNow.isHittable { owner.staticTexts["Save Password?"].firstMatch.swipeUp() }
            notNow.tap()
            return
        }
    }

    /// The number pad has no Return: Done above the keyboard puts it away (GKM-061).
    func hideKeyboard() {
        let done = app.buttons["keyboardDone"]
        if app.keyboards.firstMatch.exists, done.exists, done.isHittable { done.tap() }
    }

    // MARK: Fields

    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // At the largest text sizes the keyboard of the field before can cover this one.
        hideKeyboard()
        field.tap()
        field.typeText(text)
    }

    /// Replaces a prefilled field's text and reads it back; a try that left anything else in it
    /// (the cursor before the old text, a tap that missed) is done again from a new position.
    private func replace(_ field: XCUIElement, with text: String) {
        // On iPad the account form is a sheet, and the server fields start below its fold.
        for _ in 0..<4 where !field.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        var reads = ""
        for _ in 0..<4 {
            guard focusAtEnd(field) else { continue }
            let current = field.value as? String ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
            field.typeText(text)
            reads = field.value as? String ?? ""
            if reads == text { return }
            app.swipeDown(velocity: .slow)
        }
        XCTFail("\(field.identifier) reads \"\(reads)\", not \"\(text)\"")
    }

    /// Taps the end of the field until it has the keyboard. At the largest text sizes the
    /// keyboard of the field before, or the sheet's bar, can cover it: the keyboard is put away
    /// and the form scrolled between tries.
    private func focusAtEnd(_ field: XCUIElement) -> Bool {
        for _ in 0..<4 {
            hideKeyboard()
            if !field.isHittable { app.swipeUp(velocity: .slow) }
            if field.frame.height > 60 {
                // Wrapped: the text sits at the bottom right. Focus first, then tap its end.
                field.tap()
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.85)).tap()
            } else {
                // The fields are trailing-aligned: tap the right end so the cursor lands after
                // the old text.
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            }
            if (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false { return true }
            app.swipeDown(velocity: .slow)
        }
        return false
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

    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return condition()
    }
}
