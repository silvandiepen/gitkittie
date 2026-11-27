import XCTest
import MailClassifier
import MailCore
@testable import MailStore

/// GKM-031 in the store: a retention policy's dry run writes nothing, nothing moves unless the
/// account's active mode is on (and, for an automatic run, the policy is on and this device
/// coordinates the account), protected mail stays, every run is in the audit log without mail
/// content, and an entry can be undone on the device that made it. Two stores stand in for two
/// devices sharing the settings, as GKM-026 will sync them. Synthetic mail on example domains.
final class RetentionTests: XCTestCase {
    private var root: URL!
    private let account = MailAccountID("home")
    private let me = "sam.rivera@example.net"
    /// 26 Nov 2026, noon UTC.
    private let now = Date(timeIntervalSince1970: 1_795_694_400)
    private let archive = CleanupOperation.archive(to: "Archive", createTarget: false)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm031-retention-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func locations(_ device: String) -> StoreLocations {
        StoreLocations(mailFolder: root.appendingPathComponent("\(device)/Mail"), deviceFolder: root.appendingPathComponent("\(device)/Support/Mail"))
    }

    private static func eml(from: String, subject: String, date: String, headers: [String] = [], body: String) -> Data {
        let lines = ["From: \(from)", "To: sam.rivera@example.net", "Subject: \(subject)", "Date: \(date)",
                     "Message-ID: <\(UUID().uuidString)@example.net>"]
            + headers + ["MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8", "", body, ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private static let offerHeaders = [
        "List-ID: Shop offers <offers.shop.example>",
        "List-Unsubscribe: <https://unsubscribe.shop.example/u/abc>",
        "List-Unsubscribe-Post: List-Unsubscribe=One-Click",
        "Precedence: bulk",
    ]

    /// One device's store with the same mail: old offers (one flagged, one in a space), a recent
    /// offer, an old receipt and an old security code, all in the inbox at the provider.
    private func seeded(_ device: String) async throws -> (MailStore, [String: MailMessageID]) {
        let store = try await MailStore.open(locations(device))
        try await store.save(MailAccount(id: account, displayName: "Home", address: me))
        try await store.replaceSyncedFolders([
            SyncedFolder(name: "INBOX", path: ["INBOX"], role: "inbox"),
            SyncedFolder(name: "Archive", path: ["Archive"], role: "archive"),
            SyncedFolder(name: "Trash", path: ["Trash"], role: "trash"),
        ], account: account)
        let offer = "Shop <news@shop.example>"
        let mails: [(String, Data)] = [
            ("offer1", Self.eml(from: offer, subject: "50% off sale this weekend", date: "Thu, 01 Oct 2026 10:00:00 +0000",
                                headers: Self.offerHeaders, body: "Shop now, limited time offer.")),
            ("offer2", Self.eml(from: offer, subject: "Winter sale: 30% off boots", date: "Fri, 02 Oct 2026 10:00:00 +0000",
                                headers: Self.offerHeaders, body: "Shop now, limited time offer.")),
            ("flagged", Self.eml(from: offer, subject: "Members sale: 40% off", date: "Sat, 03 Oct 2026 10:00:00 +0000",
                                 headers: Self.offerHeaders, body: "Shop now, limited time offer.")),
            ("spaced", Self.eml(from: offer, subject: "Gift sale: 20% off", date: "Sun, 04 Oct 2026 10:00:00 +0000",
                                headers: Self.offerHeaders, body: "Shop now, limited time offer.")),
            ("recent", Self.eml(from: offer, subject: "Black Friday sale: 60% off", date: "Fri, 20 Nov 2026 10:00:00 +0000",
                                headers: Self.offerHeaders, body: "Shop now, limited time offer.")),
            ("receipt", Self.eml(from: "Shop <orders@shop.example>", subject: "Your receipt for order #101",
                                 date: "Mon, 05 Oct 2026 10:00:00 +0000", body: "Order #101. Total paid: €24.95")),
            ("code", Self.eml(from: "Shop <accounts@shop.example>", subject: "Your verification code",
                              date: "Tue, 06 Oct 2026 10:00:00 +0000", body: "Your verification code is 482913. It expires in 10 minutes.")),
        ]
        var ids: [String: MailMessageID] = [:]
        for (uid, (name, data)) in mails.enumerated() {
            ids[name] = try await store.ingest(data, account: account, remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: UInt32(uid + 1))).id
        }
        var flags: [MailMessageID: MailMessageFlags] = [:]
        for id in ids.values { flags[id] = MailMessageFlags(seen: true) }
        flags[ids["flagged"]!] = MailMessageFlags(seen: true, flagged: true)
        try await store.setFlags(flags, account: account)
        let space = try await store.createSpace(name: "Presents")
        try await store.addMessages([ids["spaced"]!], to: space.id)
        return (store, ids)
    }

    private func names(_ items: [CleanupItem], _ ids: [String: MailMessageID]) -> Set<String> {
        Set(items.compactMap { item in ids.first { $0.value == item.id }?.key })
    }

    private func boxes(_ store: MailStore, _ id: MailMessageID?) async throws -> Set<String> {
        try await store.effectiveMailboxes(of: XCTUnwrap(id))
    }

    private func activate(_ store: MailStore, coordinator: OrganisationDevice, policy: RetentionPolicy) async throws {
        var settings = try await store.organisationSettings()
        settings.set(AccountOrganisation(account: account, isActive: true, coordinator: coordinator))
        settings.set(policy)
        try await store.saveOrganisationSettings(settings)
    }

    // MARK: - Tests

    func testTheDryRunShowsWhatWouldMoveAndWhatIsProtectedAndWritesNothing() async throws {
        let (store, ids) = try await seeded("mac")
        let settings = try await store.organisationSettings()
        XCTAssertEqual(settings, OrganisationSettings(), "virtual mode everywhere until you turn something on")
        let policy = RetentionPolicy(account: account, category: .promotions)
        XCTAssertEqual(policy.days, 30, "Classification.md: promotions 30 days")
        XCTAssertEqual(RetentionPolicy(account: account, category: .subscriptions).days, 90)
        XCTAssertEqual(RetentionPolicy.suggestedDays(for: .transactions), nil, "receipts are kept indefinitely")

        let preview = try await store.previewRetention(policy, operation: archive, now: now)
        XCTAssertEqual(names(preview.included, ids), ["offer1", "offer2"])
        XCTAssertEqual(names(preview.protected, ids), ["flagged", "spaced"])
        XCTAssertEqual(preview.protected.first { $0.id == ids["flagged"] }?.protections, [.flagged])
        XCTAssertEqual(preview.protected.first { $0.id == ids["spaced"] }?.protections, [.inSpace])
        let all = Set(preview.included.map(\.id) + preview.protected.map(\.id) + preview.skipped.map(\.id))
        XCTAssertFalse(all.contains(ids["recent"]!), "younger than the policy")
        XCTAssertFalse(all.contains(ids["receipt"]!), "receipts are not a retention category")
        XCTAssertFalse(all.contains(ids["code"]!), "account security mail is never in a retention category")
        XCTAssertEqual(preview.included.first?.changes, [MailChange(ids["offer2"]!, .move(from: "INBOX", to: "Archive"))])

        let status = try await store.actionStatus(account: account)
        XCTAssertEqual(status.pending, 0, "a dry run writes nothing to the journal")
        let audit = try await store.organisationAudit()
        XCTAssertTrue(audit.isEmpty)
        for id in ids.values {
            let now = try await boxes(store, id)
            XCTAssertEqual(now, ["INBOX"])
        }
    }

    func testNothingMovesUntilActiveModeIsOnForTheAccountAndThePolicy() async throws {
        let (store, ids) = try await seeded("mac")
        let device = try await store.organisationDevice(name: "Mac")
        var policy = RetentionPolicy(account: account, category: .promotions)
        let preview = try await store.previewRetention(policy, operation: archive, now: now)

        // The account is not active: even a confirmed run moves nothing.
        do {
            try await store.runRetention(preview, policy: policy, trigger: .confirmed, device: device, now: now)
            XCTFail("ran with active mode off")
        } catch OrganisationError.accountNotActive {}

        // The account is active but the policy is off: an automatic run moves nothing.
        var settings = OrganisationSettings()
        settings.set(AccountOrganisation(account: account, isActive: true, coordinator: device))
        settings.set(policy)
        try await store.saveOrganisationSettings(settings)
        do {
            try await store.runRetention(preview, policy: policy, trigger: .automatic, device: device, now: now)
            XCTFail("ran an automatic policy that is off")
        } catch OrganisationError.policyChanged {}
        let untouched = try await boxes(store, ids["offer1"])
        XCTAssertEqual(untouched, ["INBOX"])
        let pending = try await store.actionStatus(account: account).pending
        XCTAssertEqual(pending, 0)

        // Turned on: the run moves exactly what the dry run listed.
        policy.isActive = true
        try await activate(store, coordinator: device, policy: policy)
        let entry = try await store.runRetention(preview, policy: policy, trigger: .confirmed, device: device, now: now)
        XCTAssertEqual(entry.count, 2)
        XCTAssertEqual(entry.trigger, .confirmed)
        XCTAssertEqual(entry.source, .retention(policy: policy.id, category: .promotions, days: 30))
        for name in ["offer1", "offer2"] {
            let moved = try await boxes(store, ids[name])
            XCTAssertEqual(moved, ["Archive"], name)
        }
        for name in ["flagged", "spaced", "recent", "receipt", "code"] {
            let stayed = try await boxes(store, ids[name])
            XCTAssertEqual(stayed, ["INBOX"], name)
        }
        let queued = try await store.actionStatus(account: account).pending
        XCTAssertEqual(queued, 2, "through the action journal, to be sent to the provider")

        // Turning the account off stops the next run, even of an active policy.
        var off = try await store.organisationSettings()
        off.set(AccountOrganisation(account: account, isActive: false, coordinator: device))
        try await store.saveOrganisationSettings(off)
        let next = try await store.previewRetention(policy, operation: archive, now: now)
        do {
            try await store.runRetention(next, policy: policy, trigger: .automatic, device: device, now: now)
            XCTFail("ran with the account off")
        } catch OrganisationError.accountNotActive {}
    }

    func testTheAuditLogHoldsNoMailContentAndAnEntryCanBeUndoneOnceOnItsOwnDevice() async throws {
        let (store, ids) = try await seeded("mac")
        let device = try await store.organisationDevice(name: "Mac")
        let policy = RetentionPolicy(account: account, category: .promotions, action: .trash, isActive: true)
        try await activate(store, coordinator: device, policy: policy)
        let preview = try await store.previewRetention(policy, operation: .trash(to: "Trash", createTarget: false), now: now)
        let entry = try await store.runRetention(preview, policy: policy, trigger: .confirmed, device: device, now: now)
        XCTAssertEqual(entry.action, .trash)
        XCTAssertEqual(Set(entry.moves.map(\.to)), ["Trash"])

        let audit = try await store.organisationAudit(account: account)
        XCTAssertEqual(audit.map(\.id), [entry.id])
        let file = try String(contentsOf: OrganisationAuditLog.url(in: locations("mac").deviceFolder), encoding: .utf8)
        for word in ["sale", "Shop", "shop.example", "offer", "Winter", "sam.rivera"] {
            XCTAssertFalse(file.localizedCaseInsensitiveContains(word), "the audit log holds no mail content: found “\(word)”")
        }

        // Another device cannot undo it: the message ids and the journal are this device's.
        let other = OrganisationDevice(id: "another-device", name: "iPhone")
        do {
            try await store.undoOrganisation(entry.id, device: other, now: now)
            XCTFail("undone from another device")
        } catch OrganisationError.madeOnAnotherDevice(let name) { XCTAssertEqual(name, "Mac") }

        let inverse = try await store.undoOrganisation(entry.id, device: device, now: now)
        XCTAssertNotNil(inverse)
        for name in ["offer1", "offer2"] {
            let back = try await boxes(store, ids[name])
            XCTAssertEqual(back, ["INBOX"], name)
        }
        let undone = try await store.organisationAudit().first
        XCTAssertNotNil(undone?.undoneAt)
        XCTAssertEqual(undone?.restored, 2)
        do {
            try await store.undoOrganisation(entry.id, device: device, now: now)
            XCTFail("undone twice")
        } catch OrganisationError.alreadyUndone {}
    }

    func testOnlyTheCoordinatingDeviceRunsAutomaticallyAndATakeoverMovesThatRole() async throws {
        let (mac, macIDs) = try await seeded("mac")
        let (phone, phoneIDs) = try await seeded("phone")
        let macDevice = try await mac.organisationDevice(name: "Mac")
        let phoneDevice = try await phone.organisationDevice(name: "iPhone")
        XCTAssertNotEqual(macDevice.id, phoneDevice.id)
        let policy = RetentionPolicy(account: account, category: .promotions, isActive: true)
        try await activate(mac, coordinator: macDevice, policy: policy)
        // The iPhone has the same settings, as GKM-026 syncs them.
        try await phone.saveOrganisationSettings(try await mac.organisationSettings())

        let phonePreview = try await phone.previewRetention(policy, operation: archive, now: now)
        XCTAssertEqual(phonePreview.included.count, 2, "the dry run works on every device")
        do {
            try await phone.runRetention(phonePreview, policy: policy, trigger: .automatic, device: phoneDevice, now: now)
            XCTFail("the iPhone ran although the Mac coordinates")
        } catch OrganisationError.notCoordinator {}
        let phoneUntouched = try await boxes(phone, phoneIDs["offer1"])
        XCTAssertEqual(phoneUntouched, ["INBOX"])

        let macPreview = try await mac.previewRetention(policy, operation: archive, now: now)
        let entry = try await mac.runRetention(macPreview, policy: policy, trigger: .automatic, device: macDevice, now: now)
        XCTAssertEqual(entry.count, 2)
        XCTAssertEqual(entry.device, macDevice)
        let macMoved = try await boxes(mac, macIDs["offer1"])
        XCTAssertEqual(macMoved, ["Archive"])

        // The iPhone takes over; once the Mac has the new settings it no longer runs.
        var takeover = try await phone.organisationSettings()
        takeover.set(AccountOrganisation(account: account, isActive: true, coordinator: phoneDevice))
        try await phone.saveOrganisationSettings(takeover)
        try await mac.saveOrganisationSettings(takeover)
        let again = try await mac.previewRetention(policy, operation: archive, now: now)
        do {
            try await mac.runRetention(again, policy: policy, trigger: .automatic, device: macDevice, now: now)
            XCTFail("the Mac ran after the iPhone took over")
        } catch OrganisationError.notCoordinator {}
        let phoneRun = try await phone.runRetention(phonePreview, policy: policy, trigger: .automatic, device: phoneDevice, now: now)
        XCTAssertEqual(phoneRun.count, 2)
    }

    func testAnAutomaticRunRefusesWhenTheMailChangedSinceItsPreview() async throws {
        let (store, ids) = try await seeded("mac")
        let device = try await store.organisationDevice(name: "Mac")
        let policy = RetentionPolicy(account: account, category: .promotions, isActive: true)
        try await activate(store, coordinator: device, policy: policy)
        let preview = try await store.previewRetention(policy, operation: archive, now: now)
        try await store.setFlags([ids["offer1"]!: MailMessageFlags(seen: true, flagged: true)], account: account)
        do {
            try await store.runRetention(preview, policy: policy, trigger: .automatic, device: device, now: now)
            XCTFail("ran a stale preview")
        } catch CleanupError.previewChanged(let differences) {
            XCTAssertEqual(differences.map(\.message), [ids["offer1"]!])
        }
        let audit = try await store.organisationAudit()
        XCTAssertTrue(audit.isEmpty, "nothing ran, so nothing is logged")
        let stayed = try await boxes(store, ids["offer2"])
        XCTAssertEqual(stayed, ["INBOX"])
    }

    func testARuleArchiveNeedsActiveModeAndIsLogged() async throws {
        let (store, ids) = try await seeded("mac")
        let device = try await store.organisationDevice(name: "Mac")
        let change = MailChange(ids["offer1"]!, .move(from: "INBOX", to: "Archive"))
        do {
            _ = try await store.runRuleArchive([change], rule: "rule-1", account: account, trigger: .confirmed, device: device, now: now)
            XCTFail("archived with active mode off")
        } catch OrganisationError.accountNotActive {}
        var settings = OrganisationSettings()
        settings.set(AccountOrganisation(account: account, isActive: true, coordinator: OrganisationDevice(id: "elsewhere", name: "iPad")))
        try await store.saveOrganisationSettings(settings)
        do {
            _ = try await store.runRuleArchive([change], rule: "rule-1", account: account, trigger: .automatic, device: device, now: now)
            XCTFail("archived automatically on a device that does not coordinate")
        } catch OrganisationError.notCoordinator {}
        let protected = [MailChange(ids["flagged"]!, .move(from: "INBOX", to: "Archive")),
                         MailChange(ids["spaced"]!, .move(from: "INBOX", to: "Archive"))]
        let result = try await store.runRuleArchive([change] + protected, rule: "rule-1", account: account, trigger: .confirmed,
                                                    device: device, now: now)
        XCTAssertEqual(result?.entry.source, .senderRule("rule-1"))
        XCTAssertEqual(result?.entry.count, 1, "flagged mail and mail in a space stay")
        for name in ["flagged", "spaced"] {
            let stayed = try await boxes(store, ids[name])
            XCTAssertEqual(stayed, ["INBOX"], name)
        }
        let moved = try await boxes(store, ids["offer1"])
        XCTAssertEqual(moved, ["Archive"])
    }
}
