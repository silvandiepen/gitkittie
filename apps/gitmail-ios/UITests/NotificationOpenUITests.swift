import CoreFoundation
import Foundation
import XCTest

/// A tapped notification opens its conversation after Back from the reader, against the local
/// test mail server (GKM-085). On iPhone the reader is pushed by the list's selection, so a
/// conversation older than the list's first page (200 rows) had no row to select and the tap
/// showed only the list; the list now loads pages up to it. The tap is
/// `UITestLaunch.notificationTapped`, which opens the message through the same call as a real
/// notification's tap (`AppModel.openFromNotification`).
@MainActor
final class NotificationOpenUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testANotificationOpensItsConversationAfterBackFromTheReader() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        // The notified conversation is the oldest of more than a page (200 rows): the first page
        // of the list it opens in has no row for it.
        try await server.append(["The garden plan"], for: user, dates: ["Fri, 20 Nov 2026 09:00:00 +0000"])
        try await server.append((1...200).map { "Note \($0)" }, for: user)

        app = XCUIApplication()
        app.launchArguments = ["-uiTestFreshStore"]
        app.launchEnvironment["GKM_TEST_CA_PEM_BASE64"] = server.caPEM.base64EncodedString()
        // The message the tapped notification is about.
        app.launchEnvironment["GKM_UITEST_NOTIFICATION_SUBJECT"] = "The garden plan"
        app.launch()
        AddAccountForm(app: app, test: self).add(user, on: server)

        openMailbox("Inbox")
        let rows = app.descendants(matching: .any).matching(identifier: "messageRow")
        let note = rows.containing(NSPredicate(format: "label CONTAINS 'Note '")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 60), "the inbox fills")

        // Read one conversation and go back to the list.
        note.tap()
        let subject = app.staticTexts["threadSubject"]
        XCTAssertTrue(subject.waitForExistence(timeout: 15))
        XCTAssertTrue(subject.label.hasPrefix("Note "))
        if UIDevice.current.userInterfaceIdiom == .phone {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(subject.waitForNonExistence(timeout: 10), "Back shows the list")
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        }
        snapshot("notification-1-list")

        // The notification about the other conversation is tapped: its conversation opens.
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("app.hakobs.gitmail.uitest.notificationTapped" as CFString),
                                             nil, nil, true)
        let opened = waitFor(timeout: 15) { subject.exists && subject.label == "The garden plan" }
        snapshot("notification-2-opened")
        XCTAssertTrue(opened, "the tapped notification did not open its conversation")

        // Back from it shows the list again.
        if UIDevice.current.userInterfaceIdiom == .phone {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(subject.waitForNonExistence(timeout: 10), "Back shows the list")
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        }
    }

    // MARK: Helpers

    /// On iPhone the mailboxes are a pushed column; on iPad they are on screen.
    private func openMailbox(_ title: String) {
        let row = app.descendants(matching: .any).matching(identifier: "mailbox.\(title)").firstMatch
        if !row.waitForExistence(timeout: 10) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
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
