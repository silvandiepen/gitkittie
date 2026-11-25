import Foundation
import MailCore
import MailIMAP
import MailMIME
import MailProvider
import MailStore
import MailSync
import XCTest

/// An account's folder choices and folder editing (GKM-066, MAIL-093..095) against the real local
/// mail server and a real store: folders that don't sync, special folders chosen by hand, and
/// folders created, renamed and deleted at the provider.
final class MailboxSettingsIntegrationTests: XCTestCase {
    private var server: TestMailServer!
    private var user: TestUser!
    private var captured: CapturedLog!
    private var root: URL!
    private var store: MailStore!
    private let account = MailAccountID("folders-test")
    private static let fast = ReconnectPolicy(maxAttempts: 10, initialDelay: .milliseconds(50), maxDelay: .milliseconds(200), jitter: 0)

    override func setUp() async throws {
        server = try await TestMailServer.require()
        user = try await server.makeUser(function: name)
        captured = CapturedLog()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm-folders-\(UUID().uuidString)", isDirectory: true)
        store = try await MailStore.open(StoreLocations(mailFolder: root.appendingPathComponent("Mail"),
                                                        deviceFolder: root.appendingPathComponent("Support/Mail")))
    }

    override func tearDown() async throws {
        if let user, let captured { captured.assertNoSecret(user.rawPassword) }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func imap() -> IMAPConnector {
        IMAPConnector(endpoint: ServerEndpoint(host: "localhost", port: server.imapsPort, security: .implicitTLS, trust: server.trust),
                      credential: user.credential, log: captured.log, commandTimeout: .seconds(20))
    }

    private func sync(_ mailboxes: MailboxSettings) -> SyncCoordinator {
        var options = SyncOptions(reconnect: Self.fast)
        options.mailboxes = mailboxes
        return SyncCoordinator(account: account, connector: imap(), store: store, options: options, log: captured.log)
    }

    private func editor() -> FolderEditor {
        FolderEditor(account: account, connector: imap(), store: store, log: captured.log)
    }

    private func append(_ count: Int, to folder: String, prefix: String) async throws {
        let me = MailAddress(name: "Ada Example", address: user.address)
        try await imap().withSession { session in
            if folder != "INBOX", !(try await session.listFolders().contains { $0.id == folder }) {
                try await session.createFolder(folder)
            }
            for index in 1...count {
                let raw = MIMEBuilder(from: me, to: [me], subject: "\(prefix) \(index)", textBody: "Body of \(prefix) \(index)\n").build()
                _ = try await session.append(raw, to: folder, flags: MailProvider.MessageFlags())
            }
        }
    }

    private func subjects(in mailbox: String) async throws -> [String] {
        try await store.summaries(account: account, mailbox: mailbox).compactMap(\.subject).sorted()
    }

    // MARK: - Which folders sync (MAIL-093)

    func testAFolderThatDoesntSyncIsListedButNothingIsDownloadedFromIt() async throws {
        try await append(2, to: "INBOX", prefix: "inbox")
        try await append(3, to: "Saved", prefix: "saved")
        var settings = MailboxSettings()
        settings.setSyncs(false, folder: "Saved")
        settings.setSyncs(false, folder: "INBOX") // the inbox always syncs

        let first = sync(settings)
        try await first.syncOnce()
        let stored = try await store.messageCount()
        XCTAssertEqual(stored, 2, "only the inbox")
        let names = try await store.syncedFolders(account: account).map(\.name)
        XCTAssertTrue(names.contains("Saved"), "the folder is on record, for the sidebar and settings")
        let saved = try await store.syncedFolders(account: account).first { $0.name == "Saved" }
        XCTAssertNil(saved?.uidValidity, "never opened")

        // Another client moves an inbox message into the folder that doesn't sync: it is moved,
        // not deleted at the provider.
        let inbox = try await store.syncedFolders(account: account).first { $0.name == "INBOX" }
        let validity = try XCTUnwrap(inbox?.uidValidity)
        try await imap().withSession { session in
            _ = try await session.move([RemoteMessageID(folder: "INBOX", uidValidity: validity, uid: 1)], to: "Saved")
        }
        try await first.syncOnce()
        let progress = await first.progress
        XCTAssertEqual(progress.deletedAtProvider, 0, "found in the folder that doesn't sync")
        let still = try await store.messageCount()
        XCTAssertEqual(still, 2)

        // Syncing it again brings its mail in, the moved message matched, not duplicated.
        settings.setSyncs(true, folder: "Saved")
        try await sync(settings).syncOnce()
        let all = try await store.messageCount()
        XCTAssertEqual(all, 5)
        let inSaved = try await subjects(in: "Saved")
        XCTAssertEqual(inSaved, ["inbox 1", "saved 1", "saved 2", "saved 3"])
    }

    // MARK: - Special folders chosen by hand (MAIL-094)

    func testAChosenSpecialFolderIsTheRoleOnRecordAndTheDetectedOneIsKept() async throws {
        try await imap().withSession { session in
            try await session.createFolder("Sent")
            try await session.createFolder("Outgoing")
        }
        var settings = MailboxSettings()
        settings.setSpecialFolder("Outgoing", for: "sent")
        try await sync(settings).syncOnce()
        let folders = try await store.syncedFolders(account: account)
        let sent = try XCTUnwrap(folders.first { $0.name == "Sent" })
        let outgoing = try XCTUnwrap(folders.first { $0.name == "Outgoing" })
        XCTAssertEqual(sent.detectedRole, "sent", "detected by its name")
        XCTAssertNil(sent.role, "one Sent only")
        XCTAssertEqual(outgoing.role, "sent")
        XCTAssertNil(outgoing.detectedRole)

        try await sync(MailboxSettings()).syncOnce()
        let back = try await store.syncedFolders(account: account)
        XCTAssertEqual(back.first { $0.name == "Sent" }?.role, "sent", "back to the provider's when the choice goes")
        XCTAssertNil(back.first { $0.name == "Outgoing" }?.role)
    }

    // MARK: - Folders at the provider (MAIL-095)

    func testFoldersAreCreatedRenamedAndDeletedAtTheProvider() async throws {
        let delimiter = try await imap().withSession { try await $0.hierarchyDelimiter() }
        let separator = try XCTUnwrap(delimiter, "GreenMail has folders inside folders")

        // Create, with a name that needs encoding and one inside it.
        let projects = try await editor().create(path: ["Projects"], settings: MailboxSettings()).folder
        let cafe = try await editor().create(path: ["Projects", "Café"], settings: MailboxSettings()).folder
        XCTAssertEqual(cafe, "Projects\(separator)Caf&AOk-", "modified UTF-7 at the provider")
        let created = try await imap().withSession { try await $0.listFolders() }
        XCTAssertEqual(created.first { $0.id == cafe }?.path, ["Projects", "Café"])
        let recorded = try await store.syncedFolders(account: account).map(\.name)
        XCTAssertTrue(recorded.contains(projects) && recorded.contains(cafe), "on record at once")
        do {
            _ = try await editor().create(path: ["Projects"], settings: MailboxSettings())
            XCTFail("the name is taken")
        } catch MailProviderError.invalidName {}
        do {
            _ = try await editor().create(path: ["a\(separator)b"], settings: MailboxSettings())
            XCTFail("a part can't hold the delimiter")
        } catch MailProviderError.invalidName {}

        // Rename: the mail already here stays known under the new name and the choices follow.
        try await append(2, to: projects, prefix: "project")
        try await append(1, to: cafe, prefix: "coffee")
        // GreenMail 2.1.3 drops the connection that deletes a folder an earlier session left
        // selected (README): a folder after the others makes each sync end with that one selected.
        try await append(1, to: "Zz Later", prefix: "later")
        var settings = MailboxSettings()
        settings.setShows(false, folder: cafe)
        settings.setSpecialFolder(projects, for: "archive")
        let first = sync(settings)
        try await first.syncOnce()
        let stored = try await store.messageCount()
        XCTAssertEqual(stored, 4)

        let renamed = try await editor().rename(projects, to: ["Work"], settings: settings)
        XCTAssertEqual(renamed.folder, "Work")
        let inside = "Work\(separator)Caf&AOk-"
        XCTAssertEqual(renamed.settings.hidden, [inside])
        XCTAssertEqual(renamed.settings.specialFolders, ["archive": "Work"])
        let atProvider = try await imap().withSession { try await $0.listFolders().map(\.id) }
        XCTAssertTrue(atProvider.contains("Work") && atProvider.contains(inside))
        XCTAssertFalse(atProvider.contains(projects))
        let afterRename = try await store.syncedFolders(account: account)
        XCTAssertEqual(afterRename.first { $0.name == "Work" }?.role, "archive", "the chosen role follows the folder")
        let work = try await subjects(in: "Work")
        XCTAssertEqual(work, ["project 1", "project 2"], "the folder view follows at once")

        // GreenMail lists a renamed folder after the others; one made now comes after it again.
        try await append(1, to: "Zzz After", prefix: "after")
        let again = sync(renamed.settings)
        try await again.syncOnce()
        let progress = await again.progress
        XCTAssertEqual(progress.imported, 1, "only the new folder's message: nothing in the renamed ones downloads again")
        XCTAssertEqual(progress.deletedAtProvider, 0)
        let workAfterSync = try await subjects(in: "Work")
        XCTAssertEqual(workAfterSync, ["project 1", "project 2"])
        let coffee = try await subjects(in: inside)
        XCTAssertEqual(coffee, ["coffee 1"])

        // Delete: gone at the provider and from the record; the copies stay, marked deleted there.
        let deleted = try await editor().delete(inside, settings: renamed.settings)
        XCTAssertEqual(deleted.settings.hidden, [])
        let afterDelete = try await imap().withSession { try await $0.listFolders().map(\.id) }
        XCTAssertFalse(afterDelete.contains(inside))
        let onRecord = try await store.syncedFolders(account: account).map(\.name)
        XCTAssertFalse(onRecord.contains(inside))
        let last = sync(deleted.settings)
        try await last.syncOnce()
        let marked = await last.progress
        XCTAssertEqual(marked.deletedAtProvider, 1, "the one message that was only in it")
        let kept = try await store.messageCount()
        XCTAssertEqual(kept, 5, "nothing local is deleted (Remove mail deleted elsewhere is off)")

        // The inbox can be neither renamed nor deleted.
        do {
            _ = try await editor().delete("INBOX", settings: MailboxSettings())
            XCTFail("the inbox stays")
        } catch MailProviderError.invalidName {}
    }
}
