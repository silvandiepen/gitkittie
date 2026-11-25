import XCTest
import MailAccounts
import MailClassifier
import MailCore
import MailProvider
import MailStore
import MailSync

/// The cleanup dashboard through the app model (GKM-021): looking changes nothing, the preview
/// is exactly what runs, protected mail survives every batch, Undo restores the whole batch, a
/// change at the provider between preview and run is caught, and nothing runs without
/// confirmation. A real store in a temporary folder; synthetic mail; no fakes.
@MainActor
final class CleanupTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var credentials: KeychainCredentialStore!
    private let work = MailAccountID("work")
    private let list = "deals.shop.example"
    private var ids: [String: MailMessageID] = [:]
    /// The window's undo manager; MailActions holds it weakly, as the window does.
    private var undo: UndoManager!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gitmail-cleanup-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
        defaultsSuite = "gitmail-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        credentials = KeychainCredentialStore(service: "app.hakobs.gitmail.tests.\(UUID().uuidString)", useDataProtectionKeychain: false)
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }

    private func services() -> AccountServices {
        let connections = AccountConnections(trust: .system, connectTimeout: .seconds(5), commandTimeout: .seconds(15))
        return AccountServices(
            credentials: credentials, connections: connections, verifier: AccountVerifier(connections: connections),
            syncOptions: SyncOptions(idleTimeout: .seconds(30),
                                     reconnect: ReconnectPolicy(initialDelay: .milliseconds(50), maxDelay: .milliseconds(200), jitter: 0)),
            defaults: defaults)
    }

    // MARK: - Fixtures

    private static let folders = [
        SyncedFolder(name: "INBOX", path: ["INBOX"], role: "inbox"),
        SyncedFolder(name: "Archive", path: ["Archive"], role: "archive"),
        SyncedFolder(name: "Trash", path: ["Trash"], role: "trash"),
        SyncedFolder(name: "Sent", path: ["Sent"], role: "sent"),
        SyncedFolder(name: "Shopping", path: ["Shopping"], role: nil),
    ]

    private struct Mail {
        var name: String
        var from: String
        var subject: String
        var daysAgo: Double
        var list: String?
        var folder = "INBOX"
        var inReplyTo: String?
        var attachmentBytes = 0
    }

    /// One account as the sync left it: a shop's offers list with every kind of protected
    /// message in it, a receipt and a conversation, a weekly digest, and your reply.
    private func seed() async throws {
        let store = try await MailStore.open(locations)
        try await store.save(MailAccount(id: work, displayName: "Work", address: "ada@example.com"))
        try await store.replaceSyncedFolders(Self.folders, account: work)
        let deals = "Shop Deals <deals@shop.example>"
        let digest = "News Weekly <digest@news.example>"
        let mails = [
            Mail(name: "plain1", from: deals, subject: "Winter sale: 30% off", daysAgo: 60, list: list),
            Mail(name: "plain2", from: deals, subject: "Weekend deal on boots", daysAgo: 50, list: list, attachmentBytes: 3000),
            Mail(name: "plain3", from: deals, subject: "Free shipping this week", daysAgo: 45, list: list),
            Mail(name: "flagged", from: deals, subject: "Members sale", daysAgo: 55, list: list),
            Mail(name: "spaced", from: deals, subject: "Gift deal", daysAgo: 52, list: list),
            Mail(name: "recent", from: deals, subject: "New season sale", daysAgo: 2, list: list),
            Mail(name: "replied", from: deals, subject: "Your coupon", daysAgo: 48, list: list),
            Mail(name: "answered", from: deals, subject: "Bonus offer", daysAgo: 47, list: list),
            Mail(name: "suspicious", from: deals, subject: "Discount code", daysAgo: 46, list: list),
            Mail(name: "archived", from: deals, subject: "Old deal", daysAgo: 70, list: list, folder: "Archive"),
            Mail(name: "spam", from: deals, subject: "Mega discount", daysAgo: 44, list: list),
            Mail(name: "reply", from: "Ada <ada@example.com>", subject: "Re: Your coupon", daysAgo: 47.5, folder: "Sent", inReplyTo: "replied"),
            Mail(name: "receipt", from: "Shop Orders <orders@shop.example>", subject: "Your receipt for order #4411", daysAgo: 40,
                 attachmentBytes: 3000),
            Mail(name: "conversation", from: "Bo <bo@example.net>", subject: "Lunch on Friday?", daysAgo: 30),
            Mail(name: "digest1", from: digest, subject: "Your weekly digest for Oct 12", daysAgo: 44, list: "weekly.news.example"),
            Mail(name: "digest2", from: digest, subject: "Your weekly digest for Oct 19", daysAgo: 37, list: "weekly.news.example"),
            Mail(name: "digest3", from: digest, subject: "Your weekly digest for Oct 26", daysAgo: 30, list: "weekly.news.example"),
        ]
        var uids: [String: UInt32] = [:]
        for mail in mails {
            let uid = (uids[mail.folder] ?? 0) + 1
            uids[mail.folder] = uid
            let result = try await store.ingest(Self.eml(mail), account: work,
                                                remote: RemoteLocation(mailbox: mail.folder, uidValidity: 1, uid: uid))
            ids[mail.name] = result.id
        }
        var flags: [MailMessageID: MailMessageFlags] = [:]
        for (name, id) in ids { flags[id] = MailMessageFlags(seen: name.hasPrefix("plain1")) }
        flags[ids["flagged"]!] = MailMessageFlags(flagged: true)
        flags[ids["answered"]!] = MailMessageFlags(answered: true)
        try await store.setFlags(flags, account: work)
        let space = try await store.createSpace(name: "Presents")
        try await store.addMessages([ids["spaced"]!], to: space.id)
        try await store.correct(ids["suspicious"]!, risk: .suspicious)
        try await store.correct(ids["spam"]!, risk: .spam)
    }

    private static func eml(_ mail: Mail) -> Data {
        let date = Date().addingTimeInterval(-mail.daysAgo * 24 * 3600)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var headers = "From: \(mail.from)\r\nTo: ada@example.com\r\nSubject: \(mail.subject)\r\nDate: \(formatter.string(from: date))\r\n"
        headers += "Message-ID: <\(mail.name)@test.example>\r\n"
        if let parent = mail.inReplyTo { headers += "In-Reply-To: <\(parent)@test.example>\r\nReferences: <\(parent)@test.example>\r\n" }
        if let list = mail.list {
            headers += "List-Id: Offers <\(list)>\r\nList-Unsubscribe: <https://\(list)/unsubscribe>\r\n"
        }
        guard mail.attachmentBytes > 0 else { return Data((headers + "\r\nHello from the test.\r\n").utf8) }
        let attachment = Data(repeating: 0x41, count: mail.attachmentBytes).base64EncodedString(options: .lineLength76Characters)
        let body = """
            MIME-Version: 1.0\r
            Content-Type: multipart/mixed; boundary="part"\r
            \r
            --part\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            Hello from the test.\r
            --part\r
            Content-Type: application/pdf; name="file.pdf"\r
            Content-Disposition: attachment; filename="file.pdf"\r
            Content-Transfer-Encoding: base64\r
            \r
            \(attachment)\r
            --part--\r

            """
        return Data((headers + body).utf8)
    }

    private func open() async throws -> AppModel {
        try await seed()
        let model = AppModel(locations: locations, services: services())
        await model.open()
        undo = UndoManager()
        undo.groupsByEvent = false
        model.actions.undoManager = undo
        return model
    }

    private struct State: Equatable {
        var mailboxes: Set<String>
        var seen: Bool
        var flagged: Bool
    }

    /// Every message's folders and flags as the window shows them.
    private func snapshot(_ store: MailStore) async throws -> [MailMessageID: State] {
        var result: [MailMessageID: State] = [:]
        for id in ids.values {
            let flags = try await store.flags(of: id)
            result[id] = State(mailboxes: try await store.effectiveMailboxes(of: id), seen: flags.seen, flagged: flags.flagged)
        }
        return result
    }

    private func id(_ name: String) -> MailMessageID { ids[name]! }
    private func names(_ items: [CleanupItem]) -> Set<String> { Set(items.compactMap { item in ids.first { $0.value == item.id }?.key }) }
    private var listGroup: CleanupGroupID { CleanupGroupID(account: work, kind: .list(list)) }

    private let protectedNames: Set<String> = ["flagged", "spaced", "recent", "replied", "answered", "suspicious", "spam"]

    // MARK: - Looking changes nothing

    func testTheDashboardShowsTheMailboxAndLookingChangesNothing() async throws {
        let model = try await open()
        let store = try XCTUnwrap(model.mailStore)
        let before = try await snapshot(store)

        await model.cleanup.analyse()
        let overview = try XCTUnwrap(model.cleanup.overview)
        XCTAssertEqual(overview.composition.first?.total, ids.count)
        XCTAssertEqual(overview.composition.first?.categories[.promotions]?.total, 10, "the list's offers but the spam one")
        let noisy = try XCTUnwrap(overview.noisy.first { $0.id == listGroup })
        XCTAssertEqual(noisy.count, 11)
        XCTAssertEqual(noisy.detail, list)
        XCTAssertEqual(noisy.samples.count, 5)

        let offers = try XCTUnwrap(overview.expiredOffers.first)
        XCTAssertEqual(offers.count, 9, "offers older than 30 days, not the recent one and not the one in Quarantine")
        let digest = try XCTUnwrap(overview.digests.first)
        XCTAssertEqual(digest.count, 2, "the newest issue is kept")
        XCTAssertFalse(digest.samples.contains { $0.id == id("digest3") })
        XCTAssertTrue(overview.largeMessages.isEmpty, "nothing reaches 5 MB")
        model.cleanup.options.largeMessageBytes = 2000
        await model.cleanup.analyse()
        let large = try XCTUnwrap(model.cleanup.overview?.largeMessages.first)
        XCTAssertEqual(Set(large.samples.map(\.id)), [id("plain2"), id("receipt")])

        // Selecting, opening samples and previewing every action change nothing.
        await model.cleanup.select(listGroup)
        XCTAssertEqual(model.cleanup.group?.count, 11)
        XCTAssertNil(model.cleanup.preview, "no preview until you choose an action")
        await model.cleanup.open(try XCTUnwrap(model.cleanup.group?.samples.first))
        XCTAssertTrue(model.cleanup.isReadingSample)
        for action in [CleanupAction.archive, .trash, .move(to: "Shopping")] { await model.cleanup.preview(action) }
        let after = try await snapshot(store)
        XCTAssertEqual(after, before)
        let status = try await store.actionStatus(account: work)
        XCTAssertEqual(status.pending, 0, "nothing queued for the provider")
    }

    // MARK: - Preview equals execution

    func testThePreviewIsExactlyWhatRuns() async throws {
        let model = try await open()
        let store = try XCTUnwrap(model.mailStore)
        let before = try await snapshot(store)
        await model.cleanup.select(listGroup)
        await model.cleanup.preview(.archive)
        let preview = try XCTUnwrap(model.cleanup.preview)

        XCTAssertEqual(names(preview.included), ["plain1", "plain2", "plain3"])
        XCTAssertEqual(names(preview.protected), protectedNames)
        let reasons = Dictionary(uniqueKeysWithValues: preview.protected.map { ($0.id, $0.protections) })
        XCTAssertEqual(reasons[id("flagged")], [.flagged])
        XCTAssertEqual(reasons[id("spaced")], [.inSpace])
        XCTAssertEqual(reasons[id("recent")], [.recent])
        XCTAssertEqual(reasons[id("replied")], [.repliedByYou])
        XCTAssertEqual(reasons[id("answered")], [.repliedByYou])
        XCTAssertEqual(reasons[id("suspicious")], [.uncertain])
        XCTAssertEqual(reasons[id("spam")], [.quarantined])
        XCTAssertEqual(names(preview.skipped), ["archived"])
        XCTAssertEqual(preview.skipped.first?.skip, .alreadyInTarget)
        XCTAssertTrue(preview.protected.allSatisfy(\.changes.isEmpty) && preview.skipped.allSatisfy(\.changes.isEmpty))

        // Tick one off: it stays.
        model.cleanup.toggleExclusion(id("plain2"))
        XCTAssertEqual(model.cleanup.runCount, 2)
        model.cleanup.requestRun()
        await model.cleanup.confirmRun()
        XCTAssertTrue(model.cleanup.changedSincePreview.isEmpty)
        let run = try XCTUnwrap(model.cleanup.lastRun?.run)
        XCTAssertEqual(run.messages, [id("plain3"), id("plain1")], "preview order, newest first, without the excluded one")
        XCTAssertEqual(run.batch.count, 2)

        // The journal holds exactly the previewed changes, one batch.
        let previewed = Set(preview.included.filter { $0.id != id("plain2") }.flatMap(\.changes))
        let rows = try await store.pendingActions(account: work)
        XCTAssertEqual(Set(rows.map(\.batch)).count, 1)
        let journal = Set(rows.compactMap { row -> MailChange? in
            guard let source = row.source, let target = row.target else { return nil }
            return MailChange(row.message, .move(from: source, to: target))
        })
        XCTAssertEqual(journal, previewed)
        XCTAssertEqual(rows.count, previewed.count)

        // Message for message: the run ones moved, every other message is as it was.
        let after = try await snapshot(store)
        for (id, state) in before {
            if run.messages.contains(id) {
                XCTAssertEqual(after[id]?.mailboxes, ["Archive"])
                XCTAssertEqual(after[id]?.flagged, state.flagged)
                XCTAssertEqual(after[id]?.seen, state.seen)
            } else {
                XCTAssertEqual(after[id], state)
            }
        }
    }

    // MARK: - Protected mail

    func testProtectedMailSurvivesEveryBatch() async throws {
        let model = try await open()
        let store = try XCTUnwrap(model.mailStore)
        let before = try await snapshot(store)
        model.cleanup.options.largeMessageBytes = 2000
        let large = CleanupGroupID(account: work, kind: .largeMessages)
        let groups = [listGroup, CleanupGroupID(account: work, kind: .expiredOffers), large]
        let actions: [CleanupAction] = [.archive, .trash, .move(to: "Shopping")]

        for group in groups {
            for action in actions {
                await model.cleanup.select(nil)
                await model.cleanup.select(group)
                await model.cleanup.preview(action)
                let preview = try XCTUnwrap(model.cleanup.preview)
                let protected = preview.protected.map(\.id)
                if model.cleanup.runCount > 0 {
                    model.cleanup.requestRun()
                    await model.cleanup.confirmRun()
                    XCTAssertNotNil(model.cleanup.lastRun, "\(group) \(action)")
                }
                let after = try await snapshot(store)
                for id in protected { XCTAssertEqual(after[id], before[id], "protected \(id) changed by \(action)") }
                for name in protectedNames { XCTAssertEqual(after[self.id(name)], before[self.id(name)], "\(name) changed by \(action)") }
                XCTAssertEqual(after[id("receipt")], before[id("receipt")], "receipts stay unless you include them")
                XCTAssertEqual(after[id("conversation")], before[id("conversation")])
                if model.cleanup.lastRun != nil {
                    await model.cleanup.undoLastRun()
                    let undone = try await snapshot(store)
                    XCTAssertEqual(undone, before, "\(group) \(action) undone")
                }
            }
        }

        // A receipt is protected until you include receipts, and then only that.
        await model.cleanup.select(nil)
        await model.cleanup.select(large)
        await model.cleanup.preview(.archive)
        XCTAssertEqual(model.cleanup.preview?.protected.first { $0.id == id("receipt") }?.protections, [.transaction])
        await model.cleanup.setIncludesTransactions(true)
        XCTAssertEqual(names(try XCTUnwrap(model.cleanup.preview).included), ["plain2", "receipt"])
    }

    // MARK: - Answered by Sil (GKM-021)

    /// "Mail that joins a group after you looked at the preview is left out of the run; you
    /// never saw it" (MAIL-060, MAIL-078): the run goes ahead with what was previewed and the
    /// newcomer stays where it is.
    func testMailThatJoinsTheGroupAfterThePreviewIsLeftOut() async throws {
        let model = try await open()
        let store = try XCTUnwrap(model.mailStore)
        await model.cleanup.select(listGroup)
        await model.cleanup.preview(.archive)
        XCTAssertEqual(names(try XCTUnwrap(model.cleanup.preview).included), ["plain1", "plain2", "plain3"])
        model.cleanup.requestRun()

        // The sync brings one more old offer from the same list before you confirm.
        let late = Mail(name: "late", from: "Shop Deals <deals@shop.example>", subject: "Clearance", daysAgo: 40, list: list)
        let newcomer = try await store.ingest(Self.eml(late), account: work,
                                              remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 99)).id
        ids["late"] = newcomer
        let fresh = try await store.previewCleanup(listGroup, operation: .archive(to: "Archive", createTarget: false))
        XCTAssertTrue(names(fresh.included).contains("late"), "it does belong to the group now")

        await model.cleanup.confirmRun()
        let run = try XCTUnwrap(model.cleanup.lastRun?.run, "the run is not refused because of it")
        XCTAssertEqual(Set(run.messages), [id("plain1"), id("plain2"), id("plain3")])
        let newcomerFolders = try await store.effectiveMailboxes(of: newcomer)
        XCTAssertEqual(newcomerFolders, ["INBOX"], "never part of a run you did not preview")
        XCTAssertTrue(model.cleanup.changedSincePreview.isEmpty)
    }

    /// "For messages with large attachments, offer Move to Trash? Yes" (MAIL-058, MAIL-078):
    /// the storage group previews and runs Move to Trash like the other groups.
    func testLargeMessagesCanBeMovedToTrash() async throws {
        let model = try await open()
        let store = try XCTUnwrap(model.mailStore)
        model.cleanup.options.largeMessageBytes = 2000
        await model.cleanup.select(CleanupGroupID(account: work, kind: .largeMessages))
        await model.cleanup.preview(.trash)
        let preview = try XCTUnwrap(model.cleanup.preview)
        XCTAssertEqual(names(preview.included), ["plain2"])
        XCTAssertEqual(preview.protected.first { $0.id == id("receipt") }?.protections, [.transaction])
        model.cleanup.requestRun()
        await model.cleanup.confirmRun()
        XCTAssertEqual(model.cleanup.lastRun?.run.messages, [id("plain2")])
        let folders = try await store.effectiveMailboxes(of: id("plain2"))
        XCTAssertEqual(folders, ["Trash"])
        let receipt = try await store.effectiveMailboxes(of: id("receipt"))
        XCTAssertEqual(receipt, ["INBOX"])
    }

    // MARK: - Undo

    func testUndoRestoresTheWholeBatch() async throws {
        let model = try await open()
        let store = try XCTUnwrap(model.mailStore)
        let before = try await snapshot(store)
        await model.cleanup.select(listGroup)
        await model.cleanup.preview(.trash)
        XCTAssertEqual(model.cleanup.runCount, 4, "Trash also takes the archived offer out of Archive")
        model.cleanup.requestRun()
        await model.cleanup.confirmRun()
        let trashed = try await snapshot(store)
        for name in ["plain1", "plain2", "plain3", "archived"] { XCTAssertEqual(trashed[id(name)]?.mailboxes, ["Trash"]) }
        XCTAssertEqual(model.actions.undoManager?.undoActionName, "Clean Up: Move to Trash")
        XCTAssertTrue(model.cleanup.canUndoLastRun)

        model.actions.undoManager?.undo()
        await model.actions.waitForUndo()
        let undone = try await snapshot(store)
        XCTAssertEqual(undone, before, "one Undo puts every message of the batch back")
        XCTAssertFalse(model.actions.undoManager?.canUndo ?? true, "the whole batch was one undo step")

        model.actions.undoManager?.redo()
        await model.actions.waitForUndo()
        let redone = try await snapshot(store)
        XCTAssertEqual(redone, trashed)
    }

    // MARK: - Revalidation

    func testAChangeAtTheProviderBetweenPreviewAndRunIsCaught() async throws {
        let model = try await open()
        let store = try XCTUnwrap(model.mailStore)
        await model.cleanup.select(listGroup)
        await model.cleanup.preview(.archive)
        XCTAssertEqual(model.cleanup.runCount, 3)
        model.cleanup.requestRun()

        // Meanwhile the sync learns: plain1 was flagged on the phone, plain2 was moved to
        // Shopping on the web, and you said plain3 is a receipt.
        try await store.setFlags([id("plain1"): MailMessageFlags(flagged: true)], account: work)
        try await store.forget(RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 2), account: work)
        try await store.record(RemoteLocation(mailbox: "Shopping", uidValidity: 1, uid: 1), for: id("plain2"), account: work)
        try await store.correct(id("plain3"), purpose: .transaction)
        let before = try await snapshot(store)

        await model.cleanup.confirmRun()
        XCTAssertNil(model.cleanup.lastRun, "nothing ran")
        let after = try await snapshot(store)
        XCTAssertEqual(after, before)
        let status = try await store.actionStatus(account: work)
        XCTAssertEqual(status.pending, 0)
        let changes = Dictionary(uniqueKeysWithValues: model.cleanup.changedSincePreview.map { ($0.message, $0.change) })
        XCTAssertEqual(changes[id("plain1")], .nowProtected([.flagged]))
        XCTAssertEqual(changes[id("plain2")], .nowSkipped(.notInInbox))
        guard case .nowProtected(let reasons) = changes[id("plain3")] else { return XCTFail("plain3 must be protected now") }
        XCTAssertTrue(reasons.contains(.transaction))
        XCTAssertEqual(model.cleanup.preview?.included.count, 0, "the new preview shows what is left")

        // Directly against the store: unflagged again, plain1 is the one message to move; flagged
        // once more before the run, the preview is refused.
        try await store.setFlags([id("plain1"): MailMessageFlags(flagged: false)], account: work)
        let stale = try await store.previewCleanup(listGroup, operation: .move(to: "Shopping"))
        XCTAssertEqual(names(stale.included), ["plain1", "archived"])
        try await store.setFlags([id("plain1"): MailMessageFlags(flagged: true)], account: work)
        do {
            try await store.runCleanup(stale)
            XCTFail("a stale preview must not run")
        } catch let error as CleanupError {
            guard case .previewChanged = error else { return XCTFail("\(error)") }
        }
    }

    func testAMessageMovedAtTheProviderStateIsComparedNotJustItsGroup() async throws {
        let model = try await open()
        let store = try XCTUnwrap(model.mailStore)
        // Trash takes a message out of every folder; another folder appearing changes the plan.
        let preview = try await store.previewCleanup(listGroup, operation: .trash(to: "Trash", createTarget: false))
        XCTAssertEqual(names(preview.included), ["plain1", "plain2", "plain3", "archived"])
        try await store.record(RemoteLocation(mailbox: "Shopping", uidValidity: 1, uid: 9), for: id("plain1"), account: work)
        do {
            try await store.runCleanup(preview)
            XCTFail("the plan changed")
        } catch CleanupError.previewChanged(let differences) {
            XCTAssertEqual(differences.map(\.message), [id("plain1")])
            XCTAssertEqual(differences.first?.change, .stateChanged)
        }
        _ = model
    }

    // MARK: - Confirmation

    func testNothingRunsWithoutExplicitConfirmation() async throws {
        let model = try await open()
        let store = try XCTUnwrap(model.mailStore)
        let before = try await snapshot(store)
        await model.cleanup.select(listGroup)
        await model.cleanup.preview(.archive)

        await model.cleanup.confirmRun()
        var pending = try await store.actionStatus(account: work).pending
        XCTAssertEqual(pending, 0, "confirming without asking does nothing")

        model.cleanup.requestRun()
        XCTAssertNotNil(model.cleanup.confirming)
        pending = try await store.actionStatus(account: work).pending
        XCTAssertEqual(pending, 0, "asking does nothing")
        model.cleanup.cancelRun()
        await model.cleanup.confirmRun()
        pending = try await store.actionStatus(account: work).pending
        XCTAssertEqual(pending, 0, "cancelled")

        model.cleanup.requestRun()
        model.cleanup.toggleExclusion(id("plain1"))
        XCTAssertNil(model.cleanup.confirming, "changing the selection asks again")
        await model.cleanup.confirmRun()
        model.cleanup.requestRun()
        await model.cleanup.preview(.trash)
        XCTAssertNil(model.cleanup.confirming, "a new preview asks again")
        await model.cleanup.confirmRun()
        let after = try await snapshot(store)
        XCTAssertEqual(after, before)

        for item in try XCTUnwrap(model.cleanup.preview).included where !model.cleanup.excluded.contains(item.id) {
            model.cleanup.toggleExclusion(item.id)
        }
        XCTAssertEqual(model.cleanup.runCount, 0)
        model.cleanup.requestRun()
        XCTAssertNil(model.cleanup.confirming, "nothing to run, nothing to confirm")

        do {
            let empty = try XCTUnwrap(model.cleanup.preview)
            try await store.runCleanup(empty, excluding: Set(empty.included.map(\.id)))
            XCTFail("nothing to run")
        } catch CleanupError.nothingToRun {}
    }

    // MARK: - Sender and list rules

    func testSenderSuggestionsGoThroughTheSendersRulePreview() async throws {
        let model = try await open()
        let store = try XCTUnwrap(model.mailStore)
        let before = try await snapshot(store)
        await model.cleanup.select(listGroup)
        await model.proposeSenderRule(.mute, for: listGroup)

        XCTAssertEqual(model.selection, .senders, "the rule is previewed where rules live")
        let pending = try XCTUnwrap(model.senders.pending)
        let rule = try XCTUnwrap(pending.rules.first)
        XCTAssertEqual(rule.scope.listID, list)
        XCTAssertEqual(rule.action, .mute)
        XCTAssertFalse(pending.preview.changed.isEmpty)
        let saved = try await store.senderRules()
        XCTAssertTrue(saved.isEmpty, "nothing is saved until you apply it")
        let after = try await snapshot(store)
        XCTAssertEqual(after, before)
    }

    // MARK: - Offer end dates

    func testOfferEndDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let sent = calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 9))! // a Tuesday
        func end(_ subject: String) -> DateComponents? {
            OfferExpiry.endDate(subject: subject, text: nil, sent: sent, calendar: calendar)
                .map { calendar.dateComponents([.year, .month, .day], from: $0) }
        }
        XCTAssertEqual(end("Black Friday sale ends 30 November"), DateComponents(year: 2026, month: 11, day: 30))
        XCTAssertEqual(end("Offer valid until Dec 3rd"), DateComponents(year: 2026, month: 12, day: 3))
        XCTAssertEqual(end("Sale ends Sunday"), DateComponents(year: 2026, month: 11, day: 29))
        XCTAssertEqual(end("Last day today: 20% off"), DateComponents(year: 2026, month: 11, day: 24))
        XCTAssertEqual(end("Korting geldig t/m 2 januari"), DateComponents(year: 2027, month: 1, day: 2), "next year when the date has passed")
        XCTAssertEqual(end("Ends 2026-12-01"), DateComponents(year: 2026, month: 12, day: 1))
        XCTAssertNil(end("Order by 12 December for Christmas"), "a date without an end word is no end date")
        XCTAssertNil(end("Sale ends 11/12"), "numeric dates are ambiguous")
        XCTAssertNil(end("Our winter sale"))
    }
}
