import XCTest
import MailAccounts
import MailCore
import MailProvider
import MailStore
import MailSync

/// Blocking a sender (GKM-072, MAIL-109..111) through the app model, against a real store in a
/// temporary folder: Always Junk and Always Trash from a row's menu, previewed and applied like
/// any sender rule; the sender's mail moves through the action journal, flagged mail and mail in
/// a space stay, new mail is moved after a sync, one Undo takes back the rule and the moves, and
/// removing the rule moves nothing back. With the local test mail server, the mail reaches Junk
/// and Trash at the provider, new mail too. No fakes.
@MainActor
final class BlockSenderAppTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var credentials: KeychainCredentialStore!
    private let home = MailAccountID("home")
    private let deals = MailAddress(name: "Deals", address: "deals@shop.example")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm072-block-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
        defaultsSuite = "gkm072-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        credentials = KeychainCredentialStore(service: "app.hakobs.gitmail.tests.\(UUID().uuidString)", useDataProtectionKeychain: false)
    }

    override func tearDown() async throws {
        if let locations, let store = try? await MailStore.open(locations) {
            for account in (try? await store.accounts()) ?? [] { try? credentials.delete(for: account.id) }
        }
        defaults?.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }

    private func services(trust: TrustPolicy = .system) -> AccountServices {
        let connections = AccountConnections(trust: trust, connectTimeout: .seconds(5), commandTimeout: .seconds(30))
        return AccountServices(
            credentials: credentials, connections: connections, verifier: AccountVerifier(connections: connections),
            syncOptions: SyncOptions(idleTimeout: .seconds(30),
                                     reconnect: ReconnectPolicy(initialDelay: .milliseconds(50), maxDelay: .milliseconds(200), jitter: 0)),
            defaults: defaults)
    }

    private func undoManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    private static func eml(from: String, subject: String, day: Int) -> Data {
        let lines = ["From: \(from)", "To: sam.rivera@example.net", "Subject: \(subject)",
                     String(format: "Date: %02d Nov 2026 10:00:00 +0000", day), "Message-ID: <\(UUID().uuidString)@example.net>",
                     "MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8", "", "Shop now, limited time offer.", ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private var uid: UInt32 = 0

    private func ingest(_ store: MailStore, from: String = "Deals <deals@shop.example>", subject: String, day: Int,
                        flagged: Bool = false) async throws -> MailMessageID {
        uid += 1
        let id = try await store.ingest(Self.eml(from: from, subject: subject, day: day), account: home,
                                        remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: uid)).id
        try await store.setFlags([id: MailMessageFlags(flagged: flagged)], account: home)
        return id
    }

    /// Four deals (one flagged, one in a space) and a friend, in an account whose folders the
    /// sync knows: INBOX, Trash and Junk.
    private func seed() async throws -> (plain: [MailMessageID], flagged: MailMessageID, spaced: MailMessageID, friend: MailMessageID) {
        let store = try await MailStore.open(locations)
        try await store.save(MailAccount(id: home, displayName: "Home", address: "sam.rivera@example.net"))
        try await store.replaceSyncedFolders([SyncedFolder(name: "INBOX", path: ["INBOX"], role: "inbox"),
                                              SyncedFolder(name: "Trash", path: ["Trash"], role: "trash"),
                                              SyncedFolder(name: "Junk", path: ["Junk"], role: "junk")], account: home)
        let plain = [try await ingest(store, subject: "Weekend sale", day: 1), try await ingest(store, subject: "Flash sale", day: 2)]
        let flagged = try await ingest(store, subject: "Your order shipped", day: 3, flagged: true)
        let spaced = try await ingest(store, subject: "Gift card", day: 4)
        let space = try await store.createSpace(name: "Gifts")
        _ = try await store.addMessages([spaced], to: space.id)
        let friend = try await ingest(store, from: "Ada <ada@example.org>", subject: "Lunch?", day: 5)
        return (plain, flagged, spaced, friend)
    }

    private func openModel() async -> AppModel {
        let model = AppModel(locations: locations, services: services())
        await model.open()
        await model.attention.waitForClassification()
        return model
    }

    private func boxes(_ store: MailStore, _ id: MailMessageID) async throws -> Set<String> {
        try await store.effectiveMailboxes(of: id)
    }

    // MARK: - The app model

    func testAlwaysJunkMovesTheSendersMailButNotFlaggedOrSpacedMailAndOneUndoTakesItAllBack() async throws {
        let (plain, flagged, spaced, friend) = try await seed()
        let model = await openModel()
        let store = try XCTUnwrap(model.mailStore)
        let undo = undoManager()
        model.senders.undoManager = undo
        XCTAssertNil(model.senders.blockingRule(for: deals.address, account: home))

        // From the row menu: the preview first, and nothing moves before Apply.
        await model.senders.proposeBlock(.alwaysJunk, address: deals, account: home)
        let pending = try XCTUnwrap(model.senders.pending)
        XCTAssertEqual(pending.title, "Always Junk Deals")
        XCTAssertEqual(Set(pending.preview.changed.map(\.id)), Set(plain), "the preview names what moves and nothing else")
        let kept = Dictionary(uniqueKeysWithValues: pending.preview.items.compactMap { item in item.protection.map { (item.id, $0) } })
        XCTAssertEqual(kept, [flagged: .flagged, spaced: .space])
        XCTAssertEqual(pending.notes.count, 1)
        XCTAssertTrue(pending.notes[0].hasPrefix("2 messages move to Junk now."), pending.notes[0])
        let before = try await boxes(store, plain[0])
        XCTAssertEqual(before, ["INBOX"], "a dry run changes nothing")
        let item = try XCTUnwrap(pending.preview.changed.first)
        XCTAssertEqual(SenderRuleText.placement(item.after, rules: pending.rules), "Junk")

        await model.senders.apply()
        for id in plain {
            let now = try await boxes(store, id)
            XCTAssertEqual(now, ["Junk"], "moved through the journal")
        }
        for id in [flagged, spaced, friend] {
            let now = try await boxes(store, id)
            XCTAssertEqual(now, ["INBOX"], "flagged mail, mail in a space and other senders stay where they are")
        }
        let queued = try await store.actionStatus(account: home).pending
        XCTAssertEqual(queued, 2, "two moves wait for the provider")
        let all = try await store.search(SearchQuery(), limit: 50).map(\.id)
        XCTAssertTrue(Set(all).isDisjoint(with: plain), "junked mail leaves All Mail at once (MAIL-102)")
        let rule = try XCTUnwrap(model.senders.blockingRule(for: "Deals@Shop.example", account: home))
        XCTAssertEqual(rule.action, .alwaysJunk)
        XCTAssertEqual(model.senders.blockingRules.map(\.id), [rule.id], "listed")
        XCTAssertEqual(undo.undoActionName, "Always Junk Deals")

        // One Undo: the rule goes and the mail comes back.
        undo.undo()
        await model.senders.waitForUndo()
        XCTAssertTrue(model.senders.rules.isEmpty)
        for id in plain {
            let now = try await boxes(store, id)
            XCTAssertEqual(now, ["INBOX"], "Undo takes the moves back")
        }
        // (The open rows and their inverse cancel out at the replay; the test server test
        // below proves the Undo at the provider.)

        // Redo: the rule and the moves again.
        undo.redo()
        await model.senders.waitForUndo()
        XCTAssertEqual(model.senders.rules.map(\.action), [.alwaysJunk])
        for id in plain {
            let now = try await boxes(store, id)
            XCTAssertEqual(now, ["Junk"], "Redo moves them again")
        }
    }

    func testNewMailFromABlockedSenderMovesAfterASyncAndRemovingTheRuleMovesNothingBack() async throws {
        let (plain, _, _, _) = try await seed()
        let model = await openModel()
        let store = try XCTUnwrap(model.mailStore)
        model.senders.undoManager = undoManager()
        await model.senders.proposeBlock(.alwaysTrash, address: deals, account: home)
        await model.senders.apply()
        for id in plain {
            let now = try await boxes(store, id)
            XCTAssertEqual(now, ["Trash"])
        }

        // New mail, as a sync stores it: one plain, one already flagged at the provider.
        let arrived = try await ingest(store, subject: "Last chance", day: 9)
        let arrivedFlagged = try await ingest(store, subject: "Receipt", day: 10, flagged: true)
        let other = try await ingest(store, from: "Ada <ada@example.org>", subject: "Dinner?", day: 11)
        let verdict = try await store.verdict(of: arrived)
        XCTAssertEqual(verdict?.disposition, .muted, "sorted by the rule as it arrives")
        await model.senders.afterSync()
        let movedNow = try await boxes(store, arrived)
        XCTAssertEqual(movedNow, ["Trash"], "new mail from the sender goes to Trash after the sync")
        let flaggedNow = try await boxes(store, arrivedFlagged)
        XCTAssertEqual(flaggedNow, ["INBOX"], "flagged new mail stays")
        let otherNow = try await boxes(store, other)
        XCTAssertEqual(otherNow, ["INBOX"])

        // Removing: the preview says the mail stays, and it does.
        let rule = try XCTUnwrap(model.senders.blockingRules.first)
        await model.senders.proposeRemoval(of: rule)
        let pending = try XCTUnwrap(model.senders.pending)
        XCTAssertEqual(pending.notes.count, 1)
        XCTAssertTrue(pending.notes[0].contains("stays there: removing the rule doesn’t move it back"), pending.notes[0])
        await model.senders.apply()
        XCTAssertTrue(model.senders.blockingRules.isEmpty)
        for id in plain + [arrived] {
            let now = try await boxes(store, id)
            XCTAssertEqual(now, ["Trash"], "removing a rule moves nothing back")
        }
        let later = try await ingest(store, subject: "Another sale", day: 12)
        await model.senders.afterSync()
        let laterNow = try await boxes(store, later)
        XCTAssertEqual(laterNow, ["INBOX"], "without the rule, new mail stays")
    }

    func testTheRulesAreReadWhenTheStoreOpensSoNewMailIsMovedBeforeTheSendersViewIsOpened() async throws {
        _ = try await seed()
        let rule = SenderRule(account: home, scope: .sender(deals.address), action: .alwaysJunk)
        let store = try await MailStore.open(locations)
        try await store.setSenderRules([rule])
        let model = await openModel()
        XCTAssertEqual(model.senders.blockingRule(for: deals.address, account: home)?.id, rule.id, "the row menu knows at once")
        let opened = try XCTUnwrap(model.mailStore)
        let arrived = try await ingest(opened, subject: "Big sale", day: 9)
        await model.senders.afterSync()
        let now = try await boxes(opened, arrived)
        XCTAssertEqual(now, ["Junk"])
    }

    // MARK: - With the local test mail server

    func testBlockedMailReachesJunkAndTrashAtTheProviderNewMailTooAndUndoBringsItBack() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        try await server.append(["Deal 1", "Deal 2", "Deal 3"], for: user, from: "Deals <deals@shop.example>")
        try await server.append(["Promo 1", "Promo 2"], for: user, from: "Promo <promo@ads.example>")
        try await server.append(["Keep me"], for: user)
        try await appendFlagged("Deal I flagged", to: user, on: server)
        let model = AppModel(locations: locations, services: services(trust: server.trust))
        await model.open()
        let undo = undoManager()
        model.senders.undoManager = undo

        var draft = AccountDraft()
        draft.provider = .other
        draft.address = user.address
        draft.password = user.password
        draft.imapHost = "localhost"
        draft.imapPort = server.imapsPort
        draft.smtpHost = "localhost"
        draft.smtpPort = server.smtpsPort
        draft.smtpSecurity = .implicitTLS
        draft.name = "Test"
        let account = try await model.addAccount(draft)
        let store = try XCTUnwrap(model.mailStore)
        try await waitUntil("every message stored") { try await store.messageCount() == 7 }
        try await waitUntil("the folder list") { model.sync.folders[account.id]?.isEmpty == false }
        await model.attention.waitForClassification()

        // Always Junk for Deals: the server has no Junk folder, so one is made on first use.
        await model.senders.proposeBlock(.alwaysJunk, address: deals, account: account.id)
        XCTAssertEqual(model.senders.pending?.preview.changed.count, 3)
        await model.senders.apply()
        try await waitUntil("the deals in Junk at the provider", timeout: .seconds(120)) {
            try await self.serverSubjects(server, user, "Junk") == ["Deal 1", "Deal 2", "Deal 3"]
        }

        // Always Trash for Promo.
        await model.senders.proposeBlock(.alwaysTrash, address: MailAddress(name: "Promo", address: "promo@ads.example"), account: account.id)
        await model.senders.apply()
        try await waitUntil("the promos in Trash at the provider", timeout: .seconds(120)) {
            try await self.serverSubjects(server, user, "Trash") == ["Promo 1", "Promo 2"]
        }
        let inbox = try await serverSubjects(server, user, "INBOX")
        XCTAssertEqual(inbox, ["Deal I flagged", "Keep me"], "flagged mail and other senders stay at the provider")

        // New mail from Deals arrives at the provider: after the sync it goes to Junk there too.
        try await server.append(["Deal 4"], for: user, from: "Deals <deals@shop.example>")
        await model.sync.syncNow()
        try await waitUntil("the new deal in Junk at the provider", timeout: .seconds(120)) {
            try await self.serverSubjects(server, user, "Junk") == ["Deal 1", "Deal 2", "Deal 3", "Deal 4"]
        }
        try await waitUntil("the journal to empty", timeout: .seconds(60)) { model.sync.replay[account.id]?.status.pending == 0 }

        // Undo the Always Trash: the promos come back to the inbox at the provider.
        XCTAssertEqual(undo.undoActionName, "Always Trash Promo")
        undo.undo()
        await model.senders.waitForUndo()
        try await waitUntil("the promos back in the inbox at the provider", timeout: .seconds(120)) {
            try await self.serverSubjects(server, user, "INBOX") == ["Deal I flagged", "Keep me", "Promo 1", "Promo 2"]
        }
        let trash = try await serverSubjects(server, user, "Trash")
        XCTAssertEqual(trash, [])
        await model.sync.stopAll()
    }

    private func appendFlagged(_ subject: String, to user: LocalMailServer.User, on server: LocalMailServer) async throws {
        let raw = "From: Deals <deals@shop.example>\r\nTo: \(user.address)\r\nSubject: \(subject)\r\nMessage-ID: <\(UUID().uuidString)@example.net>\r\nDate: Tue, 24 Nov 2026 09:00:00 +0000\r\n\r\nFlagged.\r\n"
        try await AccountConnections(trust: server.trust).imap(settings(server, user), password: Secret(user.password)).withSession { session in
            _ = try await session.append(Data(raw.utf8), to: "INBOX", flags: MailProvider.MessageFlags(flagged: true), receivedAt: nil)
        }
    }

    private func settings(_ server: LocalMailServer, _ user: LocalMailServer.User) -> MailConnectionSettings {
        MailConnectionSettings(
            kind: .imap,
            imap: MailServerSettings(host: "localhost", port: server.imapsPort, security: .implicitTLS, username: user.address),
            smtp: MailServerSettings(host: "localhost", port: server.smtpsPort, security: .implicitTLS, username: user.address))
    }

    private func serverSubjects(_ server: LocalMailServer, _ user: LocalMailServer.User, _ folder: String) async throws -> [String] {
        try await AccountConnections(trust: server.trust).imap(settings(server, user), password: Secret(user.password)).withSession { session in
            guard try await session.listFolders().contains(where: { $0.id == folder }) else { return [] }
            let listing = try await session.listing(of: folder)
            guard !listing.uids.isEmpty else { return [] }
            let ids = listing.uids.map { RemoteMessageID(folder: folder, uidValidity: listing.status.uidValidity, uid: $0) }
            return try await session.summaries(of: ids).compactMap(\.subject).sorted()
        }
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(60), _ condition: () async throws -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now + timeout
        while clock.now < end {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("timed out waiting for \(what)")
    }
}
