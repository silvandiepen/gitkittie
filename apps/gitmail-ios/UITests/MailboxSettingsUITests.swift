import Foundation
import MailAccounts
import MailCore
import MailProvider
import XCTest

/// An account's mailboxes in Settings on a simulator, against the local test mail server
/// (GKM-066): a folder made, hidden, renamed and deleted from Settings ▸ the account ▸ Mailboxes
/// reaches the provider. Screenshots of the screens are attached to the result.
@MainActor
final class MailboxSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testAFolderIsMadeHiddenRenamedAndDeletedFromSettings() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        try await server.append(["Welcome"], for: user)

        app = XCUIApplication()
        app.launchArguments = ["-uiTestFreshStore"]
        app.launchEnvironment["GKM_TEST_CA_PEM_BASE64"] = server.caPEM.base64EncodedString()
        app.launch()
        addAccount(user)

        // Settings ▸ the account ▸ Mailboxes.
        let settings = app.buttons["settingsButton"]
        if !settings.waitForExistence(timeout: 10) { app.navigationBars.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let accountRow = app.buttons.matching(identifier: "settingsAccountRow").firstMatch
        XCTAssertTrue(accountRow.waitForExistence(timeout: 10))
        accountRow.tap()
        let mailboxes = app.buttons["accountMailboxesLink"]
        if !mailboxes.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(mailboxes.waitForExistence(timeout: 5))
        snapshot("settings-account")
        mailboxes.tap()
        XCTAssertTrue(element("mailboxRow-INBOX").waitForExistence(timeout: 45), "the folders after the first sync")

        // New folder, at the provider.
        app.buttons["newFolderButton"].tap()
        // A system alert's field doesn't carry SwiftUI's accessibility identifier: find it in the alert.
        let newName = app.alerts["New Folder"].textFields.firstMatch
        XCTAssertTrue(newName.waitForExistence(timeout: 5))
        newName.typeText("Receipts")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(element("mailboxRow-Receipts").waitForExistence(timeout: 20), "listed once made")
        let made = try await serverFolders(server, user)
        XCTAssertTrue(made.contains("Receipts"))
        snapshot("settings-mailboxes")

        // Hide it from the mailbox list, then rename it.
        element("mailboxRow-Receipts").tap()
        let show = app.switches["folderShowToggle"]
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        tapSwitch(show)
        XCTAssertTrue(waitFor(timeout: 10) { (show.value as? String) == "0" }, "the folder is hidden")
        snapshot("settings-folder")
        app.buttons["renameFolderButton"].tap()
        let rename = app.alerts["Rename Folder"].textFields.firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()
        rename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + "Bills")
        app.alerts.buttons["Rename"].tap()
        XCTAssertTrue(app.navigationBars["Bills"].waitForExistence(timeout: 20), "renamed")
        let renamed = try await serverFolders(server, user)
        XCTAssertTrue(renamed.contains("Bills"))
        XCTAssertFalse(renamed.contains("Receipts"))
        XCTAssertEqual(show.value as? String, "0", "the choice followed the folder")

        // Delete asks first, then the folder is gone at the provider.
        app.buttons["deleteFolderButton"].tap()
        let confirm = app.buttons["confirmDeleteFolder"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "deleting asks first")
        snapshot("settings-delete")
        confirm.tap()
        XCTAssertTrue(element("mailboxRow-Bills").waitForNonExistence(timeout: 20))
        let left = try await serverFolders(server, user)
        XCTAssertFalse(left.contains("Bills"))
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
        let security = app.buttons["smtpSecurityPicker"]
        if !security.isHittable { app.swipeUp() }
        security.tap()
        let tls = app.buttons["TLS"]
        XCTAssertTrue(tls.waitForExistence(timeout: 5))
        tls.tap()
        app.buttons["addAccountConfirm"].tap()
        XCTAssertTrue(app.textFields["addressField"].waitForNonExistence(timeout: 45), "the account was not added")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A Form's switch is toggled by its control, at the trailing edge.
    private func tapSwitch(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
    }

    private func replace(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        if !field.isHittable { app.swipeUp() }
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        field.typeText(text)
    }

    private func serverFolders(_ server: LocalMailServer, _ user: LocalMailServer.User) async throws -> [String] {
        let settings = MailConnectionSettings(
            kind: .imap,
            imap: MailServerSettings(host: "localhost", port: server.imapsPort, security: .implicitTLS, username: user.address),
            smtp: MailServerSettings(host: "localhost", port: server.smtpsPort, security: .implicitTLS, username: user.address))
        return try await AccountConnections(trust: server.trust).imap(settings, password: Secret(user.password)).withSession { session in
            try await session.listFolders().map(\.id)
        }
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
