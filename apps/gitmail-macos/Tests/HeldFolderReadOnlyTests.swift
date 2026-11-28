import XCTest
import MailAccounts
import MailCompose
import MailCore
import MailStore
import MailSync

/// A mail folder held back for being in iCloud Drive or a File Provider folder is opened
/// read-only (GKM-104, MAIL-135): across opening, browsing, a draft, an import, a space edit,
/// an account change and the outbox, no file in the folder is created, changed or removed, and
/// each refusal says why in the words of the held notice. The placement is injected
/// (`AccountServices.folderPlacement`); the folder is a real one in a temporary directory, so
/// nothing here touches iCloud Drive.
@MainActor
final class HeldFolderReadOnlyTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var credentials: KeychainCredentialStore!
    private let work = MailAccountID("work")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm104-held-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
        defaultsSuite = "gkm104-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        credentials = KeychainCredentialStore(service: "app.hakobs.gitmail.tests.\(UUID().uuidString)", useDataProtectionKeychain: false)
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }

    private func services(placement: MailFolderPlacement) -> AccountServices {
        let connections = AccountConnections(connectTimeout: .seconds(5), commandTimeout: .seconds(15))
        var services = AccountServices(
            credentials: credentials, connections: connections, verifier: AccountVerifier(connections: connections),
            syncOptions: SyncOptions(), defaults: defaults)
        services.folderPlacement = { _ in placement }
        services.freeSpace = { _ in 100_000_000_000 }
        return services
    }

    private let message = Data("""
    From: Bo <bo@example.net>\r
    To: Ada <ada@example.com>\r
    Subject: Dinner on Friday\r
    Date: Mon, 23 Nov 2026 18:00:00 +0000\r
    Message-ID: <dinner-1@example.net>\r
    \r
    Shall we?\r

    """.utf8)

    /// A folder as an earlier, ordinary run left it: a connected account, two messages, a space, a
    /// saved draft and a message waiting in the outbox; and what a crash leaves behind (a
    /// temporary file in the month folder, a journal file) for opening to tidy up if it may.
    private func seedFolder() async throws -> URL {
        var draft = AccountDraft()
        draft.provider = .other
        draft.address = "ada@example.test"
        draft.imapHost = "imap.example.test"
        draft.smtpHost = "smtp.example.test"
        draft.password = "never saved"
        let account = MailAccount(id: work, displayName: "Work", address: draft.trimmedAddress, connection: try draft.connection())
        let store = try await MailStore.open(locations)
        try await store.save(account)
        let first = try await store.ingest(message, account: work)
        try await store.ingest(Data(String(decoding: message, as: UTF8.self)
            .replacingOccurrences(of: "dinner-1", with: "dinner-2").utf8), account: work)
        _ = try await store.createSpace(name: "Dinners")
        let month = try await store.message(first.id).emlURL.deletingLastPathComponent()
        let stray = month.appendingPathComponent(".left-behind.partial")
        try Data("half".utf8).write(to: stray)

        // A saved draft and a queued send, made the way the app makes them.
        let seeding = AppModel(locations: locations, services: services(placement: .onThisDevice))
        await seeding.open()
        let sending = try XCTUnwrap(seeding.sending)
        sending.pumpInterval = .seconds(3600)
        let id = await seeding.composeNew()
        XCTAssertNotNil(id)
        var outgoing = ComposeDraft(account: work, from: account.sendingAddress)
        outgoing.to = [MailAddress(address: "kim@example.org")]
        outgoing.subject = "Waiting"
        outgoing.body = "Queued before the folder was held."
        let saved = try await sending.save(outgoing).draft
        try await sending.send(saved)
        for _ in 0..<200 where sending.outbox.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(sending.outbox.count, 1)
        await sending.stop()
        await seeding.sync.stopAll()

        // After the seeding model: it may have tidied the stray file; put it back, and the journal.
        try Data("half".utf8).write(to: stray)
        let journal = locations.deviceFolder.appendingPathComponent("state/journal", isDirectory: true)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: journal.appendingPathComponent("broken.json"))
        return stray
    }

    private func importable() throws -> URL {
        let folder = root.appendingPathComponent("To Import", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(String(decoding: message, as: UTF8.self)
            .replacingOccurrences(of: "dinner-1", with: "dinner-3").utf8).write(to: folder.appendingPathComponent("three.eml"))
        return folder
    }

    func testAHeldFolderTakesNoWriteOfAnyKind() async throws {
        let stray = try await seedFolder()
        let toImport = try importable()
        let before = try FolderSnapshot(of: locations.mailFolder)
        XCTAssertFalse(before.paths.isEmpty)
        let reason = try XCTUnwrap(MailFolderPlacement.iCloudDrive.readOnlyText)

        // Open.
        let model = AppModel(locations: locations, services: services(placement: .iCloudDrive))
        await model.open()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.sync.folderHold, .iCloudDrive)
        XCTAssertEqual(model.writeRefusal, reason)
        XCTAssertFalse(model.canWrite)
        let store = try XCTUnwrap(model.mailStore)
        let deferred = await store.recoveryDeferred
        XCTAssertTrue(deferred, "the crash leftovers were not tidied")

        // Browse: the mail is there to read, open and search.
        XCTAssertEqual(model.totalCount, 2)
        await model.select(.allMail)
        let row = try XCTUnwrap(model.browser.rows.first)
        await model.browser.select(row.id)
        XCTAssertNotNil(model.browser.openThread)
        await model.select(.drafts)
        XCTAssertEqual(model.sending?.drafts.count, 1, "the saved draft can be read")
        await model.select(.outbox)
        XCTAssertEqual(model.sending?.outbox.count, 1, "the queued send is listed")

        // A draft, a reply, an import, a space, an account change, a rebuild: each refused, with the reason.
        XCTAssertFalse(model.canAnswer)
        let newDraft = await model.composeNew()
        XCTAssertNil(newDraft)
        XCTAssertEqual(model.actionError, reason)
        model.actionError = nil
        let sending = try XCTUnwrap(model.sending)
        do {
            _ = try await sending.newDraft(from: nil)
            XCTFail("a draft was written")
        } catch {
            XCTAssertEqual(String(describing: error), reason, "the store's own refusal says the same")
        }
        await model.importMessages(from: [toImport])
        XCTAssertEqual(model.actionError, reason)
        XCTAssertNil(model.importReport)
        model.actionError = nil
        let space = await model.spaces.create(name: "Taxes", icon: "folder", color: "blue")
        XCTAssertNil(space)
        XCTAssertEqual(model.spaces.actionError, reason)
        model.spaces.actionError = nil
        _ = await model.spaces.refresh(applyRules: true)
        XCTAssertNil(model.spaces.actionError, "rules are not applied, which would write; that is not an error")
        do {
            try await model.updateAccountSettings(work, displayName: "Renamed", senderName: "Ada", removesMailDeletedElsewhere: false)
            XCTFail("an account was changed")
        } catch {
            XCTAssertEqual(String(describing: error), reason)
        }
        do {
            try await model.removeAccount(work, .removeMail)
            XCTFail("an account was removed")
        } catch {
            XCTAssertEqual(String(describing: error), reason)
        }
        await model.rebuildIndex()
        XCTAssertEqual(model.actionError, reason)
        model.actionError = nil
        for command: MenuCommand in [.newMessage, .importMessages, .answer(.reply)] {
            XCTAssertEqual(model.unavailableReason(command), reason)
            XCTAssertFalse(model.canRun(command))
        }
        model.actionError = nil

        // The outbox is paused: nothing is retried, checked or cancelled, and nothing is sent.
        let queued = try XCTUnwrap(sending.outbox.first)
        await sending.retry(queued.id)
        XCTAssertEqual(sending.lastError, reason)
        sending.lastError = nil
        await sending.cancel(queued.id)
        XCTAssertEqual(sending.lastError, reason)
        sending.pumpInterval = .milliseconds(1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sending.outbox.first?.state, .queued)
        XCTAssertEqual(sending.outbox.first?.attempts, 0)

        await sending.stop()
        await model.sync.stopAll()
        let after = try FolderSnapshot(of: locations.mailFolder)
        XCTAssertEqual(after.differences(from: before), [], "nothing in the held folder changed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
    }

    func testANormalFolderStillWritesAndTidiesUp() async throws {
        let stray = try await seedFolder()
        let toImport = try importable()
        let before = try FolderSnapshot(of: locations.mailFolder)

        let model = AppModel(locations: locations, services: services(placement: .onThisDevice))
        await model.open()
        XCTAssertNil(model.writeRefusal)
        XCTAssertTrue(model.canWrite)
        let store = try XCTUnwrap(model.mailStore)
        let deferred = await store.recoveryDeferred
        XCTAssertFalse(deferred)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path), "recovery removed the temporary file")

        let draft = await model.composeNew()
        XCTAssertNotNil(draft)
        XCTAssertNil(model.actionError)
        await model.importMessages(from: [toImport])
        XCTAssertEqual(model.importReport?.imported, 1)
        let space = await model.spaces.create(name: "Taxes", icon: "folder", color: "blue")
        XCTAssertNotNil(space)
        XCTAssertTrue(model.canRun(.newMessage))
        try await model.updateAccountSettings(work, displayName: "Renamed", senderName: "", removesMailDeletedElsewhere: false)

        await model.sending?.stop()
        await model.sync.stopAll()
        let after = try FolderSnapshot(of: locations.mailFolder)
        let changed = after.differences(from: before)
        XCTAssertTrue(changed.contains { $0.hasPrefix("added") && $0.contains("/drafts/") }, "\(changed)")
        XCTAssertTrue(changed.contains { $0.hasPrefix("added") && $0.contains("/spaces/") }, "\(changed)")
        XCTAssertTrue(changed.contains { $0.hasPrefix("added") && $0.hasSuffix(".eml") }, "\(changed)")
        XCTAssertTrue(changed.contains { $0.hasPrefix("changed") && $0.hasSuffix("account.json") }, "\(changed)")
    }

    func testAHeldFolderWithNothingToTidyOpensAndDoesNotSayRecoveryWasSkipped() async throws {
        let store = try await MailStore.open(locations)
        try await store.save(MailAccount(id: work, displayName: "Work", address: "ada@example.com"))
        let model = AppModel(locations: locations, services: services(placement: .cloudStorage))
        await model.open()
        let held = try XCTUnwrap(model.mailStore)
        let deferred = await held.recoveryDeferred
        XCTAssertFalse(deferred)
        XCTAssertEqual(model.writeRefusal, MailFolderPlacement.cloudStorage.readOnlyText)
        await model.sending?.stop()
    }
}
