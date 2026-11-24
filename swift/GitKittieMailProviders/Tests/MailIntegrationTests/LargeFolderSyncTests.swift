import Foundation
import MailCore
import MailIMAP
import MailProvider
import MailStore
import MailSync
import XCTest

/// A folder larger than the small ones the other sync tests use (GKM-035, docs/Performance.md),
/// against the real local server: its listing is one response line of more than 8 KB, and its
/// history takes several passes.
final class LargeFolderSyncTests: XCTestCase {
    private var server: TestMailServer!
    private var user: TestUser!
    private var captured: CapturedLog!
    private var root: URL!
    private let account = MailAccountID("large-folder")

    override func setUp() async throws {
        server = try await TestMailServer.require()
        user = try await server.makeUser(function: name)
        captured = CapturedLog()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm-large-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        if let user, let captured { captured.assertNoSecret(user.rawPassword) }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func imap() -> IMAPConnector {
        IMAPConnector(endpoint: server.imaps, credential: user.credential, log: captured.log, commandTimeout: .seconds(60))
    }

    func testAFolderOfTwoThousandSyncsCompletelyAndChecksFlagsOnlyAtTheStartAndEndOfItsHistory() async throws {
        // UID SEARCH ALL answers with about 8.9 KB on one line: over swift-nio-imap's default limit.
        let count = 2_000
        let me = "Ada Example <\(user.address)>"
        try await imap().withSession { session in
            for index in 1...count {
                let raw = "From: \(me)\r\nTo: \(me)\r\nSubject: message \(index)\r\nMessage-ID: <large-\(index)@example.com>\r\n"
                    + "Date: Tue, 24 Nov 2026 10:00:00 +0000\r\n\r\nBody of message \(index).\r\n"
                _ = try await session.append(Data(raw.utf8), to: "INBOX", flags: MailProvider.MessageFlags(seen: index % 3 == 0))
            }
        }
        let store = try await MailStore.open(StoreLocations(mailFolder: root.appendingPathComponent("Mail"),
                                                            deviceFolder: root.appendingPathComponent("Support/Mail")))
        // 100 recent, then 1,900 of history in five passes of up to 400.
        let sync = SyncCoordinator(account: account, connector: imap(), store: store,
                                   options: SyncOptions(recentPerFolder: 100, historyPerPass: 400), log: captured.log)
        try await sync.syncOnce()

        let stored = try await store.messageCount()
        XCTAssertEqual(stored, count, "the listing of a folder this size is read in full")
        let folders = try await store.syncedFolders(account: account)
        XCTAssertEqual(folders.first?.historyComplete, true)
        let unread = try await store.unreadCount(account: account, mailbox: "INBOX")
        XCTAssertEqual(unread, count - count / 3, "every message has the provider's flags")

        // Flags are read for what is stored when the sync starts (100 messages: one command)
        // and once when the history is complete (2,000: four commands of 500), not on each of
        // the history passes in between (which read 500, 900, … 1,700 messages again).
        let flagReads = captured.lines.filter { $0.contains("→") && $0.contains("× FLAGS)") }.count
        XCTAssertEqual(flagReads, 1 + 4, captured.lines.filter { $0.contains("→") && $0.contains("× FLAGS)") }.joined(separator: "\n"))
    }
}
