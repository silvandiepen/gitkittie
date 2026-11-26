import XCTest
import MailClassifier
import MailCore
@testable import MailStore

/// GKM-072 in the store: Always Junk and Always Trash. The rule is planned and previewed like any
/// sender rule; what it would move leaves out flagged mail, mail in a space and account security
/// mail, and acts on spam from the sender too; flags and spaces are read again when the mail is
/// moved. Synthetic addresses on reserved example domains.
final class BlockingRulesTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let account = MailAccountID("home")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm072-block-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func open() async throws -> MailStore {
        let store = try await MailStore.open(locations)
        try await store.save(MailAccount(id: account, displayName: "Home", address: "sam.rivera@example.net"))
        return store
    }

    private func ingest(_ store: MailStore, from: String = "Deals <deals@shop.example>", subject: String, day: Int,
                        body: String = "Shop now, limited time offer.") async throws -> MailMessageID {
        try await store.ingest(SenderRulesTests.eml(from: from, subject: subject, day: day, body: body), account: account).id
    }

    func testAlwaysJunkPlansEveryMessageButFlaggedSpacedAndSecurityMailAndActsOnSpam() async throws {
        let store = try await open()
        let plain = try await ingest(store, subject: "Weekend sale", day: 1)
        let flagged = try await ingest(store, subject: "Order shipped", day: 2)
        let spaced = try await ingest(store, subject: "Gift card", day: 3)
        let security = try await ingest(store, subject: "Your verification code", day: 4,
                                        body: "Your verification code is 482913. Someone tried to sign in to your account.")
        let spam = try await ingest(store, subject: "You are a winner! Claim your prize now", day: 5,
                                    body: "Congratulations, you have won a lottery prize. Act now, wire transfer the claim fee.")
        let other = try await ingest(store, from: "Ada <ada@example.org>", subject: "Lunch?", day: 6, body: "Lunch on Friday?")
        try await store.setFlags(MessageFlags(flagged: true), for: flagged)
        let space = try await store.createSpace(name: "Gifts")
        _ = try await store.addMessages([spaced], to: space.id)
        let securityVerdict = try await store.verdict(of: security)
        XCTAssertEqual(securityVerdict?.classification.purpose, .security, "fixture: account security mail")
        let spamVerdict = try await store.verdict(of: spam)
        XCTAssertNotEqual(spamVerdict?.classification.risk, MailRisk.none, "fixture: the classifier doubts it")

        let rule = SenderRule(account: account, scope: .sender("deals@shop.example"), action: .alwaysJunk)
        let preview = try await store.previewSenderRules([rule])
        XCTAssertEqual(Set(preview.items.map(\.id)), [plain, flagged, spaced, security, spam], "only the sender's mail")
        let protections = Dictionary(uniqueKeysWithValues: preview.items.map { ($0.id, $0.protection) })
        XCTAssertEqual(protections[flagged], .flagged)
        XCTAssertEqual(protections[spaced], .space)
        XCTAssertEqual(protections[security], .security)
        XCTAssertNil(protections[spam] ?? nil, "a block acts on risky mail: moving it out of the way is the safer side")
        XCTAssertEqual(Set(preview.changed.map(\.id)), [plain, spam])
        let nothingSaved = try await store.senderRules()
        XCTAssertEqual(nothingSaved, [], "a preview saves nothing")

        let (_, result) = try await store.setSenderRules([rule])
        XCTAssertEqual(Set(result.changed.map(\.id)), Set(preview.changed.map(\.id)), "applying does what the preview said")
        let toMove = try await store.messagesToBlock(by: rule)
        XCTAssertEqual(Set(toMove), [plain, spam])
        let otherVerdict = try await store.verdict(of: other)
        XCTAssertNil(otherVerdict?.senderRule)
        let saved = try await store.senderRules()
        XCTAssertEqual(saved.first?.action, .alwaysJunk, "the kind is saved with the rule")

        // Flagged after it was sorted: read again at the moment of the move, it stays.
        try await store.setFlags(MessageFlags(flagged: true), for: plain)
        let afterFlag = try await store.messagesToBlock(by: rule)
        XCTAssertEqual(afterFlag, [spam])
        let among = try await store.messagesToBlock(by: rule, among: [spam, other])
        XCTAssertEqual(among, [spam], "only what the rule decided")

        var off = rule
        off.isEnabled = false
        let none = try await store.messagesToBlock(by: off)
        XCTAssertEqual(none, [], "a rule that is off moves nothing")
    }

    func testBlockedMailAlreadyInTrashOrJunkHasNothingToMove() async throws {
        let store = try await open()
        try await store.replaceSyncedFolders([SyncedFolder(name: "INBOX", path: ["INBOX"], role: "inbox"),
                                              SyncedFolder(name: "Trash", path: ["Trash"], role: "trash")], account: account)
        let inTrash = try await store.ingest(SenderRulesTests.eml(from: "deals@shop.example", subject: "Old sale", day: 1, body: "Sale."),
                                             account: account, remote: RemoteLocation(mailbox: "Trash", uidValidity: 1, uid: 1)).id
        let inInbox = try await store.ingest(SenderRulesTests.eml(from: "deals@shop.example", subject: "New sale", day: 2, body: "Sale."),
                                             account: account, remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 2)).id
        let rule = SenderRule(account: account, scope: .sender("deals@shop.example"), action: .alwaysTrash)
        let preview = try await store.previewSenderRules([rule])
        XCTAssertEqual(preview.items.first { $0.id == inTrash }?.isInTrashOrJunk, true)
        XCTAssertEqual(preview.items.first { $0.id == inInbox }?.isInTrashOrJunk, false)
        try await store.setSenderRules([rule])
        let toMove = try await store.messagesToBlock(by: rule)
        XCTAssertEqual(toMove, [inInbox])
    }

    func testWithoutAJunkFolderTheJunkCreatedOnFirstUseCounts() async throws {
        let store = try await open()
        try await store.replaceSyncedFolders([SyncedFolder(name: "INBOX", path: ["INBOX"], role: "inbox")], account: account)
        let id = try await store.ingest(SenderRulesTests.eml(from: "deals@shop.example", subject: "Sale", day: 1, body: "Sale."),
                                        account: account, remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 1)).id
        try await store.perform([MailChange(id, .move(from: "INBOX", to: "Junk", createTarget: true))])
        let gone = try await store.isOnlyInTrashOrJunk(id)
        XCTAssertTrue(gone, "mail moved to the Junk made on first use leaves the other views at once")
        let all = try await store.search(SearchQuery(), limit: 10).map(\.id)
        XCTAssertFalse(all.contains(id))
    }
}
