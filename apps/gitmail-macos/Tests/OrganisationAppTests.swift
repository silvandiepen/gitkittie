import XCTest
import MailAccounts
import MailClassifier
import MailCore
import MailProvider
import MailStore
import MailSync

/// Active organisation and retention (GKM-031, MAIL-115..119) through the app model, against a
/// real store in a temporary folder: a dry run moves nothing, nothing moves until active mode is
/// on for the account and the policy, turning a policy on runs exactly its dry run, every step is
/// in the history and can be undone there, automatic work waits while the device is not caught
/// up with the provider, and a sender rule archives at the provider only with active mode on.
/// With the local test mail server: two devices on one account, only the coordinating one moves
/// mail, a takeover moves that role, and a device whose sync is stopped waits and then resumes.
/// No fakes.
@MainActor
final class OrganisationAppTests: XCTestCase {
    private var roots: [URL] = []
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var credentials: KeychainCredentialStore!
    private let home = MailAccountID("home")

    override func setUp() async throws {
        defaultsSuite = "gkm031-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        credentials = KeychainCredentialStore(service: "app.hakobs.gitmail.tests.\(UUID().uuidString)", useDataProtectionKeychain: false)
    }

    override func tearDown() async throws {
        for root in roots {
            let locations = Self.locations(root)
            if let store = try? await MailStore.open(locations) {
                for account in (try? await store.accounts()) ?? [] { try? credentials.delete(for: account.id) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        defaults?.removePersistentDomain(forName: defaultsSuite)
    }

    private static func locations(_ root: URL) -> StoreLocations {
        StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    /// A new device: its own mail folder and device folder.
    private func newDevice() -> StoreLocations {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm031-org-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return Self.locations(root)
    }

    private func services(trust: TrustPolicy = .system) -> AccountServices {
        let connections = AccountConnections(trust: trust, connectTimeout: .seconds(5), commandTimeout: .seconds(30))
        return AccountServices(
            credentials: credentials, connections: connections, verifier: AccountVerifier(connections: connections),
            syncOptions: SyncOptions(idleTimeout: .seconds(30),
                                     reconnect: ReconnectPolicy(initialDelay: .milliseconds(50), maxDelay: .milliseconds(200), jitter: 0)),
            defaults: defaults)
    }

    private static let offerHeaders = [
        "List-ID: Shop offers <offers.shop.example>",
        "List-Unsubscribe: <https://unsubscribe.shop.example/u/abc>",
        "List-Unsubscribe-Post: List-Unsubscribe=One-Click",
        "Precedence: bulk",
    ]

    private static func rfc822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    /// An offer from the shop's list (a promotion), dated `daysAgo` days ago.
    private static func offer(_ subject: String, daysAgo: Double, to: String = "sam.rivera@example.net") -> Data {
        let lines = ["From: Shop <news@shop.example>", "To: \(to)", "Subject: \(subject)",
                     "Date: \(rfc822(Date().addingTimeInterval(-daysAgo * 86_400)))", "Message-ID: <\(UUID().uuidString)@example.net>"]
            + offerHeaders + ["MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8", "", "Shop now, limited time offer.", ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    // MARK: - Without a server

    private var uid: UInt32 = 0

    private func ingest(_ store: MailStore, _ subject: String, daysAgo: Double, flagged: Bool = false) async throws -> MailMessageID {
        uid += 1
        let id = try await store.ingest(Self.offer(subject, daysAgo: daysAgo), account: home,
                                        remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: uid)).id
        try await store.setFlags([id: MailMessageFlags(seen: true, flagged: flagged)], account: home)
        return id
    }

    private func openSeeded() async throws -> (AppModel, MailStore, [String: MailMessageID]) {
        let locations = newDevice()
        let store = try await MailStore.open(locations)
        try await store.save(MailAccount(id: home, displayName: "Home", address: "sam.rivera@example.net"))
        try await store.replaceSyncedFolders([SyncedFolder(name: "INBOX", path: ["INBOX"], role: "inbox"),
                                              SyncedFolder(name: "Archive", path: ["Archive"], role: "archive"),
                                              SyncedFolder(name: "Trash", path: ["Trash"], role: "trash")], account: home)
        var ids: [String: MailMessageID] = [:]
        ids["old1"] = try await ingest(store, "50% off sale this weekend", daysAgo: 60)
        ids["old2"] = try await ingest(store, "Winter sale: 30% off boots", daysAgo: 45)
        ids["flagged"] = try await ingest(store, "Members sale: 40% off", daysAgo: 50, flagged: true)
        ids["young"] = try await ingest(store, "Black Friday sale: 60% off", daysAgo: 3)
        let model = AppModel(locations: locations, services: services())
        await model.open()
        let opened = try XCTUnwrap(model.mailStore)
        return (model, opened, ids)
    }

    private func boxes(_ store: MailStore, _ id: MailMessageID?) async throws -> Set<String> {
        try await store.effectiveMailboxes(of: XCTUnwrap(id))
    }

    func testADryRunMovesNothingAndAPolicyRunsOnlyOnceActiveModeAndThePolicyAreOn() async throws {
        let (model, store, ids) = try await openSeeded()
        let organisation = model.organisation
        XCTAssertFalse(organisation.isActive(home), "virtual mode by default")
        let policy = organisation.policy(for: home, category: .promotions)
        XCTAssertEqual(policy.days, 30)
        XCTAssertFalse(policy.isActive)

        // The dry run, with the account still off: what would move, what stays, nothing moved.
        await organisation.preview(policy)
        let dry = try XCTUnwrap(organisation.dryRun)
        XCTAssertEqual(Set(dry.preview.included.map(\.id)), [ids["old1"]!, ids["old2"]!])
        XCTAssertEqual(dry.preview.protected.map(\.id), [ids["flagged"]!])
        XCTAssertEqual(OrganisationText.dryRun(dry.preview),
                       "Dry run: nothing has moved. 2 messages would move from your inbox to “Archive” at your mail provider.")
        await organisation.turnOn()
        XCTAssertEqual(organisation.notice, OrganisationError.accountNotActive.description, "the account is off: nothing runs")
        organisation.notice = nil
        for id in ids.values {
            let now = try await boxes(store, id)
            XCTAssertEqual(now, ["INBOX"])
        }
        XCTAssertTrue(organisation.audit.isEmpty)
        let pending = try await store.actionStatus(account: home).pending
        XCTAssertEqual(pending, 0)

        // Active mode on for the account: this Mac runs it. Still nothing moves by itself.
        await organisation.setActive(true, account: home)
        XCTAssertTrue(organisation.isActive(home))
        XCTAssertTrue(organisation.coordinatesHere(home))
        await organisation.afterSync()
        let stillHere = try await boxes(store, ids["old1"])
        XCTAssertEqual(stillHere, ["INBOX"], "no policy is on")

        // Turned on from its dry run: exactly the dry run runs.
        await organisation.preview(policy)
        await organisation.turnOn()
        XCTAssertNil(organisation.notice)
        XCTAssertNil(organisation.dryRun)
        for name in ["old1", "old2"] {
            let moved = try await boxes(store, ids[name])
            XCTAssertEqual(moved, ["Archive"], name)
        }
        for name in ["flagged", "young"] {
            let stayed = try await boxes(store, ids[name])
            XCTAssertEqual(stayed, ["INBOX"], name)
        }
        XCTAssertEqual(organisation.policy(for: home, category: .promotions).isActive, true)
        let entry = try XCTUnwrap(organisation.audit.first)
        XCTAssertEqual(entry.trigger, .confirmed)
        XCTAssertEqual(entry.count, 2)
        XCTAssertEqual(OrganisationText.summary(entry), "Archived 2 messages")
        XCTAssertEqual(OrganisationText.source(entry, rules: []), "Promotions older than 30 days")

        // Mail that ages in after that waits: without a sync this Mac is not caught up.
        let aged = try await ingest(store, "Autumn sale: 25% off", daysAgo: 40)
        await organisation.afterSync()
        XCTAssertEqual(organisation.pauses[home], .reconciling)
        let waiting = try await boxes(store, aged)
        XCTAssertEqual(waiting, ["INBOX"], "paused: nothing moves")

        // Undo from the history puts both back, and turns the policy off so it doesn't move them again.
        await organisation.undo(entry)
        for name in ["old1", "old2"] {
            let back = try await boxes(store, ids[name])
            XCTAssertEqual(back, ["INBOX"], name)
        }
        XCTAssertNotNil(organisation.audit.first?.undoneAt)
        XCTAssertFalse(organisation.policy(for: home, category: .promotions).isActive)
        XCTAssertEqual(organisation.notice, OrganisationText.offAfterUndo(organisation.policy(for: home, category: .promotions)))
        organisation.notice = nil

        // A new age turns the policy off: it needs a new dry run.
        await organisation.update(organisation.policy(for: home, category: .promotions), days: 60)
        let changed = organisation.policy(for: home, category: .promotions)
        XCTAssertEqual(changed.days, 60)
        XCTAssertFalse(changed.isActive)

        // Turning the account off turns its policies off.
        await organisation.preview(changed)
        await organisation.turnOn()
        XCTAssertTrue(organisation.policy(for: home, category: .promotions).isActive)
        await organisation.setActive(false, account: home)
        XCTAssertFalse(organisation.policy(for: home, category: .promotions).isActive)
    }

    func testTheGateWaitsUnlessThisDeviceCoordinatesIsOnlineCaughtUpAndHasNothingQueued() {
        let mac = OrganisationDevice(id: "mac", name: "Mac")
        let on = AccountOrganisation(account: home, isActive: true, coordinator: mac)
        var watching = SyncProgress()
        watching.activity = .watching(folder: "INBOX")
        watching.lastCompletedPass = Date()
        let idle = ReplayProgress()

        XCTAssertNil(OrganisationPause.check(on, device: mac, progress: watching, replay: idle))
        XCTAssertEqual(OrganisationPause.check(nil, device: mac, progress: watching, replay: idle), .accountOff)
        XCTAssertEqual(OrganisationPause.check(AccountOrganisation(account: home, isActive: false, coordinator: mac), device: mac,
                                               progress: watching, replay: idle), .accountOff)
        XCTAssertEqual(OrganisationPause.check(AccountOrganisation(account: home, isActive: true), device: mac, progress: watching, replay: idle),
                       .noCoordinator)
        XCTAssertEqual(OrganisationPause.check(on, device: OrganisationDevice(id: "phone", name: "iPhone"), progress: watching, replay: idle),
                       .otherDevice("Mac"))
        XCTAssertEqual(OrganisationPause.check(on, device: mac, progress: nil, replay: idle), .reconciling, "no sync running")

        var offline = watching
        offline.activity = .waitingToRetry(reason: "no route to host", retryAt: Date().addingTimeInterval(60))
        XCTAssertEqual(OrganisationPause.check(on, device: mac, progress: offline, replay: idle), .offline)
        var stopped = watching
        stopped.activity = .stopped
        XCTAssertEqual(OrganisationPause.check(on, device: mac, progress: stopped, replay: idle), .offline)
        var signIn = watching
        signIn.activity = .signInFailed(reason: "refused")
        XCTAssertEqual(OrganisationPause.check(on, device: mac, progress: signIn, replay: idle), .signInNeeded)
        var importing = watching
        importing.activity = .importing(folder: "INBOX")
        XCTAssertEqual(OrganisationPause.check(on, device: mac, progress: importing, replay: idle), .reconciling)
        var firstPass = watching
        firstPass.lastCompletedPass = nil
        XCTAssertEqual(OrganisationPause.check(on, device: mac, progress: firstPass, replay: idle), .reconciling)

        var replayOffline = ReplayProgress()
        replayOffline.activity = .offline(reason: "timed out", retryAt: Date())
        XCTAssertEqual(OrganisationPause.check(on, device: mac, progress: watching, replay: replayOffline), .offline)
        var queued = ReplayProgress()
        queued.status.pending = 3
        XCTAssertEqual(OrganisationPause.check(on, device: mac, progress: watching, replay: queued), .changesWaiting(3))
        var failed = ReplayProgress()
        failed.status.failed = 1
        XCTAssertEqual(OrganisationPause.check(on, device: mac, progress: watching, replay: failed), .changesWaiting(1))
    }

    func testASenderRuleArchivesAtTheProviderOnlyWithActiveModeOnAndIsInTheHistory() async throws {
        let (model, store, ids) = try await openSeeded()
        await model.senders.refresh()
        let sender = try XCTUnwrap(model.senders.senders.first { $0.scope.listID == "offers.shop.example" })

        // Active mode off: the rule mutes, and nothing is archived at the provider.
        await model.senders.propose(.mute, for: sender, archiveAtProvider: true)
        await model.senders.apply()
        await model.senders.lastProviderArchive?.value
        let virtual = try await boxes(store, ids["old1"])
        XCTAssertEqual(virtual, ["INBOX"], "virtual: active mode is off for the account")
        XCTAssertTrue(model.organisation.audit.isEmpty)

        // Active mode on: applying the rule archives what it silenced, as one step in the history.
        await model.organisation.setActive(true, account: home)
        let rule = try XCTUnwrap(model.senders.rules.first)
        await model.senders.proposeEnabled(false, rule: rule)
        await model.senders.apply()
        await model.senders.proposeEnabled(true, rule: try XCTUnwrap(model.senders.rules.first))
        await model.senders.apply()
        await model.senders.lastProviderArchive?.value
        for name in ["old1", "old2", "young"] {
            let archived = try await boxes(store, ids[name])
            XCTAssertEqual(archived, ["Archive"], name)
        }
        let flagged = try await boxes(store, ids["flagged"])
        XCTAssertEqual(flagged, ["INBOX"], "flagged mail stays where it is")
        let entry = try XCTUnwrap(model.organisation.audit.first)
        XCTAssertEqual(entry.source, .senderRule(rule.id))
        XCTAssertEqual(entry.trigger, .confirmed)
        XCTAssertEqual(OrganisationText.source(entry, rules: model.senders.rules), "Sender rule for offers.shop.example")

        // New mail the rule silences after a sync waits while this Mac isn't caught up …
        let arrived = try await ingest(store, "Cyber Monday sale: 70% off", daysAgo: 0)
        await model.senders.afterSync()
        let waiting = try await boxes(store, arrived)
        XCTAssertEqual(waiting, ["INBOX"], "paused: no sync has caught up")
        XCTAssertEqual(model.organisation.pauses[home], .reconciling)
    }

    // MARK: - With the local test mail server: two devices

    func testOnlyTheCoordinatingDeviceMovesMailATakeoverMovesThatRoleAndAStoppedDeviceWaits() async throws {
        let server = try await LocalMailServer.require()
        let user = try await server.makeUser()
        try await append(Self.offer("Old sale 1", daysAgo: 60, to: user.address), to: user, on: server, daysAgo: 60)
        try await append(Self.offer("Old sale 2", daysAgo: 45, to: user.address), to: user, on: server, daysAgo: 45)
        try await append(Self.offer("Flagged sale", daysAgo: 50, to: user.address), to: user, on: server, daysAgo: 50, flagged: true)
        try await server.append(["Lunch on Friday?"], for: user)

        // The Mac: adds the account, turns active mode on and the promotions policy from its dry run.
        let mac = try await addDevice(user, server: server, expecting: 4)
        let policy = mac.organisation.policy(for: mac.accounts[0].id, category: .promotions)
        let account = policy.account
        await mac.organisation.setActive(true, account: account)
        await mac.organisation.preview(policy)
        XCTAssertEqual(mac.organisation.dryRun?.preview.included.count, 2)
        await mac.organisation.turnOn()
        XCTAssertNil(mac.organisation.notice)
        try await waitUntil("the old sales archived at the provider") {
            try await self.serverSubjects(server, user, "Archive") == ["Old sale 1", "Old sale 2"]
        }
        let inbox = try await serverSubjects(server, user, "INBOX")
        XCTAssertEqual(inbox, ["Flagged sale", "Lunch on Friday?"], "flagged mail and the conversation stay")

        // A second device on the same account, with the same settings (as GKM-026 syncs them).
        let phone = try await secondDevice(mac.accounts[0], server: server, expecting: 4)
        try await share(from: mac, to: phone)
        XCTAssertFalse(phone.organisation.coordinatesHere(account))

        // An old sale arrives. The second device sees it and waits; the Mac moves it.
        try await append(Self.offer("Old sale 3", daysAgo: 40, to: user.address), to: user, on: server, daysAgo: 40)
        await phone.sync.syncNow()
        try await waitUntil("the second device has the new sale") { try await self.has("Old sale 3", phone) }
        await phone.organisation.afterSync()
        XCTAssertEqual(phone.organisation.pauses[account], .otherDevice("Mac"))
        let phoneQueued = try await XCTUnwrap(phone.mailStore).actionStatus(account: account).pending
        XCTAssertEqual(phoneQueued, 0, "the second device writes nothing")
        XCTAssertTrue(phone.organisation.audit.isEmpty)
        await mac.sync.syncNow()
        try await waitUntil("the Mac moves the new sale after its sync", timeout: .seconds(120)) {
            await mac.organisation.afterSync()
            return try await self.serverSubjects(server, user, "Archive") == ["Old sale 1", "Old sale 2", "Old sale 3"]
        }
        XCTAssertEqual(mac.organisation.audit.map(\.trigger), [.automatic, .confirmed])

        // The second device takes over; once the Mac has the new settings it waits instead.
        await phone.organisation.coordinateHere(account)
        try await share(from: phone, to: mac)
        XCTAssertFalse(mac.organisation.coordinatesHere(account))
        try await append(Self.offer("Old sale 4", daysAgo: 35, to: user.address), to: user, on: server, daysAgo: 35)
        await mac.sync.syncNow()
        try await waitUntil("the Mac has the new sale") { try await self.has("Old sale 4", mac) }
        await mac.organisation.afterSync()
        XCTAssertEqual(mac.organisation.pauses[account], .otherDevice("Mac"))
        let macQueued = try await XCTUnwrap(mac.mailStore).actionStatus(account: account).pending
        XCTAssertEqual(macQueued, 0)
        await phone.sync.syncNow()
        try await waitUntil("the second device moves it", timeout: .seconds(120)) {
            await phone.organisation.afterSync()
            return try await self.serverSubjects(server, user, "Archive") == ["Old sale 1", "Old sale 2", "Old sale 3", "Old sale 4"]
        }

        // A sale that ages in while the second device's sync is stopped waits until it runs again.
        try await append(Self.offer("Sale 5", daysAgo: 20, to: user.address), to: user, on: server, daysAgo: 20)
        await phone.sync.syncNow()
        try await waitUntil("the second device has sale 5") { try await self.has("Sale 5", phone) }
        try await waitUntil("its journal is empty") { phone.sync.replay[account]?.status.pending == 0 }
        await phone.sync.stopAll()
        phone.organisation.now = { Date().addingTimeInterval(15 * 86_400) } // sale 5 is 35 days old now
        await phone.organisation.afterSync()
        XCTAssertEqual(phone.organisation.pauses[account], .reconciling, "no sync: not caught up with the provider")
        let stillInInbox = try await serverSubjects(server, user, "INBOX")
        XCTAssertEqual(stillInInbox, ["Flagged sale", "Lunch on Friday?", "Sale 5"])
        await phone.sync.start(phone.accounts, store: try XCTUnwrap(phone.mailStore))
        try await waitUntil("sale 5 moved once the second device is back", timeout: .seconds(120)) {
            await phone.organisation.afterSync()
            return try await self.serverSubjects(server, user, "Archive").contains("Sale 5")
        }

        // Undo of the Mac's automatic step, from its history, after the journal let go of it. The
        // second device runs the policy, so its sync is stopped first: with the settings not
        // shared yet (GKM-026) it would move the mail again.
        await phone.sync.stopAll()
        let macStore = try XCTUnwrap(mac.mailStore)
        try await waitUntil("the Mac's journal is empty") { mac.sync.replay[account]?.status.pending == 0 }
        try await macStore.pruneActionJournal(account: account, now: Date().addingTimeInterval(8 * 86_400))
        let automatic = try XCTUnwrap(mac.organisation.audit.first { $0.trigger == .automatic })
        await mac.organisation.undo(automatic)
        XCTAssertNotEqual(mac.organisation.notice, "Nothing went back: every message has moved on since.")
        try await waitUntil("old sale 3 back in the inbox at the provider", timeout: .seconds(120)) {
            try await self.serverSubjects(server, user, "INBOX").contains("Old sale 3")
        }
        await mac.sync.stopAll()
        await phone.sync.stopAll()
    }

    // MARK: - Helpers

    private func addDevice(_ user: LocalMailServer.User, server: LocalMailServer, expecting count: Int) async throws -> AppModel {
        let model = AppModel(locations: newDevice(), services: services(trust: server.trust))
        await model.open()
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
        try await waitUntil("every message stored") { try await store.messageCount() == count }
        try await waitUntil("the folder list") { model.sync.folders[account.id]?.isEmpty == false }
        await model.attention.waitForClassification()
        return model
    }

    /// Another device with the same account (same id, as the shared mail folder of GKM-026 has
    /// it; the password is in the same test keychain), synced from the server on its own.
    private func secondDevice(_ account: MailAccount, server: LocalMailServer, expecting count: Int) async throws -> AppModel {
        let locations = newDevice()
        try await MailStore.open(locations).save(account)
        let model = AppModel(locations: locations, services: services(trust: server.trust))
        await model.open()
        let store = try XCTUnwrap(model.mailStore)
        try await waitUntil("every message stored on the second device") { try await store.messageCount() == count }
        try await waitUntil("the folder list") { model.sync.folders[account.id]?.isEmpty == false }
        await model.attention.waitForClassification()
        return model
    }

    /// What GKM-026 will do: the other device gets these settings.
    private func share(from source: AppModel, to target: AppModel) async throws {
        let settings = try await XCTUnwrap(source.mailStore).organisationSettings()
        try await XCTUnwrap(target.mailStore).saveOrganisationSettings(settings)
        await target.organisation.refresh()
    }

    private func has(_ subject: String, _ model: AppModel) async throws -> Bool {
        let store = try XCTUnwrap(model.mailStore)
        let found = try await store.search(SearchQuery(text: subject), limit: 10).contains { $0.subject == subject }
        guard found else { return false }
        await model.attention.waitForClassification()
        return true
    }

    private func append(_ raw: Data, to user: LocalMailServer.User, on server: LocalMailServer, daysAgo: Double,
                        flagged: Bool = false) async throws {
        try await AccountConnections(trust: server.trust).imap(settings(server, user), password: Secret(user.password)).withSession { session in
            _ = try await session.append(raw, to: "INBOX", flags: MailProvider.MessageFlags(flagged: flagged),
                                         receivedAt: Date().addingTimeInterval(-daysAgo * 86_400))
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
            try await Task.sleep(for: .milliseconds(300))
        }
        XCTFail("timed out waiting for \(what)")
    }
}
