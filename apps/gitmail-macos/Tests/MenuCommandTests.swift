import AppKit
import XCTest
import MailCore
import MailStore

/// The checks the menu bar's shortcut commands make as they run (GITKITTIE-098), against a real
/// store in a temporary folder, and the compose windows' directory with real windows.
@MainActor
final class MenuCommandTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let work = MailAccountID("work")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gitmail-menu-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let shortcutCommands: [MenuCommand] = [
        .newMessage, .answer(.reply), .answer(.replyAll), .answer(.forward),
        .importMessages, .searchMail, .syncNow, .messageAction,
    ]

    /// At launch the store is still opening: every command says so instead of doing nothing,
    /// and the reason goes to the alert.
    func testWhileTheMailOpensEveryCommandSaysSo() {
        let model = AppModel(locations: locations)
        XCTAssertEqual(model.phase, .opening)
        for command in Self.shortcutCommands {
            XCTAssertEqual(model.unavailableReason(command), "Your mail is still opening. Try again in a moment.", "\(command)")
        }
        XCTAssertFalse(model.canRun(.newMessage))
        XCTAssertEqual(model.actionError, "Your mail is still opening. Try again in a moment.")
    }

    /// The same commands follow the model once it opens: the state at launch does not stick.
    func testOnceOpenTheCommandsFollowTheModel() async throws {
        try await seed()
        let model = AppModel(locations: locations)
        XCTAssertFalse(model.canRun(.newMessage))
        await model.open()
        XCTAssertEqual(model.phase, .ready)
        model.actionError = nil

        XCTAssertNil(model.unavailableReason(.newMessage))
        XCTAssertNil(model.unavailableReason(.searchMail))
        XCTAssertNil(model.unavailableReason(.importMessages))
        XCTAssertTrue(model.canRun(.newMessage))
        XCTAssertNil(model.actionError, "a command that can run leaves the alert alone")

        // Nothing selected yet.
        XCTAssertEqual(model.unavailableReason(.answer(.reply)), "Open a message to reply to it.")
        XCTAssertEqual(model.unavailableReason(.answer(.replyAll)), "Open a message to reply to it.")
        XCTAssertEqual(model.unavailableReason(.answer(.forward)), "Open a message to forward it.")
        XCTAssertEqual(model.unavailableReason(.messageAction), "Select a conversation first.")
        XCTAssertFalse(model.canRun(.messageAction))
        XCTAssertEqual(model.actionError, "Select a conversation first.")

        // Selecting a conversation opens it: Reply and the everyday actions can run.
        let row = try XCTUnwrap(model.browser.rows.first)
        await model.browser.select(row.id)
        XCTAssertNil(model.unavailableReason(.answer(.reply)))
        XCTAssertNil(model.unavailableReason(.answer(.forward)))
        XCTAssertNil(model.unavailableReason(.messageAction))
        XCTAssertEqual(model.unavailableReason(.answer(.reply)) == nil, model.canAnswer)

        // The account has no provider connection: nothing to sync, and it says what to do.
        XCTAssertEqual(model.unavailableReason(.syncNow), "There’s no account to sync. Add one with Mailbox ▸ Add Account….")
        await model.sending?.stop()
    }

    func testAFolderThatCannotOpenSaysSo() async {
        let bad = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Mail/state"))
        let model = AppModel(locations: bad)
        await model.open()
        guard case .failed = model.phase else { return XCTFail("expected failure, got \(model.phase)") }
        for command in Self.shortcutCommands {
            XCTAssertEqual(model.unavailableReason(command), "Your mail folder couldn’t be opened, so this can’t be done.", "\(command)")
        }
    }

    /// Send, Attach Files… and Delete Draft… act on the compose window in front when they run,
    /// never on another one, and on none when the window in front isn't a compose window.
    func testTheComposeWindowInFrontIsTheOneTheMenuActsOn() {
        let directory = ComposeWindowDirectory()
        let mail = window()
        let first = window()
        let second = window()
        var sent: [String] = []
        directory.set(commands(canSend: true) { sent.append("first") }, for: first)
        directory.set(commands(canSend: true) { sent.append("second") }, for: second)
        XCTAssertEqual(directory.count, 2)

        directory.commands(inFront: second)?.send()
        directory.commands(inFront: first)?.send()
        XCTAssertEqual(sent, ["second", "first"])
        XCTAssertNil(directory.commands(inFront: mail), "the mail window is not a compose window")
        XCTAssertNil(directory.commands(inFront: nil), "no window in front")

        // A window that is sending says it can't send again; a closed one is gone.
        directory.set(commands(canSend: false) {}, for: first)
        XCTAssertEqual(directory.commands(inFront: first)?.canSend, false)
        directory.set(nil, for: second)
        XCTAssertNil(directory.commands(inFront: second))
        XCTAssertEqual(directory.count, 1)
    }

    private func window() -> NSWindow {
        // Never shown: only its identity is used.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private func commands(canSend: Bool, send: @escaping @MainActor () -> Void) -> ComposeWindowCommands {
        ComposeWindowCommands(canSend: canSend, send: send, requestAttach: {}, requestDiscard: {})
    }

    private func seed() async throws {
        let store = try await MailStore.open(locations)
        try await store.save(MailAccount(id: work, displayName: "Work", address: "ada@example.com"))
        try await store.ingest(Data("""
        From: Bo <bo@example.net>\r
        To: ada@example.com\r
        Subject: Dinner on Friday\r
        Date: Mon, 23 Nov 2026 18:00:00 +0000\r
        Message-ID: <dinner-1@example.net>\r
        \r
        Shall we?\r

        """.utf8), account: work)
    }
}
