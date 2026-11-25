import MailCore
import XCTest

/// An account's folder choices (GKM-066, MAIL-093, MAIL-094).
final class MailboxSettingsTests: XCTestCase {
    private let detected: [(name: String, role: String?)] = [
        ("INBOX", "inbox"), ("Sent", "sent"), ("Deleted", "trash"), ("Bin", nil), ("Archive", "archive"),
        ("Saved", nil), ("[Gmail]/All Mail", "all"),
    ]

    func testNothingChosenIsWhatTheProviderSaid() {
        let roles = MailboxSettings().effectiveRoles(detected: detected)
        XCTAssertEqual(roles["Sent"], .some("sent"))
        XCTAssertEqual(roles["Bin"], .some(nil))
    }

    func testAChosenFolderTakesTheRoleFromTheDetectedOne() {
        var settings = MailboxSettings()
        settings.setSpecialFolder("Bin", for: "trash")
        let roles = settings.effectiveRoles(detected: detected)
        XCTAssertEqual(roles["Bin"], .some("trash"))
        XCTAssertEqual(roles["Deleted"], .some(nil), "one Trash only")
    }

    func testAFolderHasOneRoleAndFixedRolesNeverMove() {
        var settings = MailboxSettings()
        settings.setSpecialFolder("Saved", for: "archive")
        settings.setSpecialFolder("Saved", for: "trash")
        XCTAssertEqual(settings.specialFolders, ["trash": "Saved"], "choosing it again takes it from the other role")
        settings.setSpecialFolder("[Gmail]/All Mail", for: "archive")
        settings.setSpecialFolder("INBOX", for: "junk")
        let roles = settings.effectiveRoles(detected: detected)
        XCTAssertEqual(roles["[Gmail]/All Mail"], .some("all"), "All Mail is never Archive by hand: a move out of it deletes")
        XCTAssertEqual(roles["Archive"], .some("archive"))
        XCTAssertEqual(roles["INBOX"], .some("inbox"))
        XCTAssertEqual(roles["Saved"], .some("trash"))
    }

    func testAChoiceForAFolderThatIsGoneIsIgnored() {
        var settings = MailboxSettings()
        settings.setSpecialFolder("Gone", for: "sent")
        XCTAssertEqual(settings.effectiveRoles(detected: detected)["Sent"], .some("sent"))
    }

    func testTheInboxAlwaysSyncs() {
        var settings = MailboxSettings()
        settings.setSyncs(false, folder: "INBOX")
        settings.setSyncs(false, folder: "Saved")
        XCTAssertTrue(settings.syncs("INBOX", detectedRole: "inbox"))
        XCTAssertFalse(settings.syncs("Saved", detectedRole: nil))
        settings.setSyncs(true, folder: "Saved")
        XCTAssertTrue(settings.syncs("Saved", detectedRole: nil))
    }

    func testOrderPutsTheChosenOnesFirstAndKeepsTheRestInTheProvidersOrder() {
        let settings = MailboxSettings(order: ["Saved", "INBOX"])
        XCTAssertEqual(settings.ordered(detected.map(\.name), name: { $0 }),
                       ["Saved", "INBOX", "Sent", "Deleted", "Bin", "Archive", "[Gmail]/All Mail"])
    }

    func testRenamingAndRemovingFollowTheFolderAndWhatIsInside() {
        var settings = MailboxSettings(notSynced: ["Projects/Old", "Projectsish"], hidden: ["Projects"], order: ["Projects", "INBOX"],
                                       specialFolders: ["archive": "Projects/Done"])
        settings.renameFolder("Projects", to: "Work", delimiter: "/")
        XCTAssertEqual(settings.notSynced, ["Projectsish", "Work/Old"])
        XCTAssertEqual(settings.hidden, ["Work"])
        XCTAssertEqual(settings.order, ["Work", "INBOX"])
        XCTAssertEqual(settings.specialFolders, ["archive": "Work/Done"])
        settings.removeFolder("Work", delimiter: "/")
        XCTAssertEqual(settings, MailboxSettings(notSynced: ["Projectsish"], order: ["INBOX"]))
    }

    func testAnAccountFileWithoutTheSettingsStillReads() throws {
        let json = #"{"id":"a","displayName":"Work","address":"a@example.com"}"#
        let account = try JSONDecoder().decode(MailAccount.self, from: Data(json.utf8))
        XCTAssertNil(account.mailboxes)
        let partial = try JSONDecoder().decode(MailboxSettings.self, from: Data(#"{"hidden":["Bin"]}"#.utf8))
        XCTAssertEqual(partial, MailboxSettings(hidden: ["Bin"]))
    }
}
