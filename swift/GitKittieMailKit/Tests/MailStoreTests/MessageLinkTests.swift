import CryptoKit
import XCTest
import MailCore
@testable import MailStore

/// Stable message links (GKM-033, MAIL-131): `gitkittie-mail://message/<account>/<key>` names a
/// message by what the message itself carries, so the link still opens it after the index is
/// rebuilt, after the mail is downloaded afresh (new local ids), and from an account added again.
final class MessageLinkTests: XCTestCase {
    private var root: URL!
    private let work = MailAccountID("acct-work")
    private let home = MailAccountID("acct-home")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm033-links-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func locations(_ name: String) -> StoreLocations {
        StoreLocations(mailFolder: root.appendingPathComponent("\(name)/Mail"), deviceFolder: root.appendingPathComponent("\(name)/Support/Mail"))
    }

    private let invoice = SyntheticMail.plain(from: "Ada Lovelace <ada@example.com>", subject: "Invoice 114 for the garden",
                                              messageID: "inv-114.2026@mail.example.com", body: "The total is 1,250 euro.")
    /// No Message-ID: named by its content fingerprint instead.
    private let note = SyntheticMail.plain(subject: "A note without an id", body: "Just a note.")

    private func makeLink(_ store: MailStore, _ id: MailMessageID) async throws -> MessageLink {
        let link = try await store.link(to: id)
        return try XCTUnwrap(link)
    }

    // MARK: The link

    /// The link is the account and a hash: nothing of the message (no Message-ID, sender,
    /// subject or text) is readable in it, since it goes to Tasks cards and Git.
    func testALinkNamesTheMessageWithoutSayingAnythingAboutIt() async throws {
        let store = try await MailStore.open(locations("a"))
        let id = try await store.ingest(invoice, account: work).id
        let link = try await makeLink(store, id)
        let hash = SHA256.hash(data: Data("inv-114.2026@mail.example.com".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(link.url.absoluteString, "gitkittie-mail://message/acct-work/m-\(hash)")
        for secret in ["inv-114", "example.com", "ada", "Ada", "Invoice", "garden", "1,250", id.rawValue] {
            XCTAssertFalse(link.url.absoluteString.contains(secret), "\(secret) is in \(link)")
        }
        XCTAssertEqual(MessageLink(url: link.url), link, "round trip")
    }

    func testOnlyWellFormedLinksAreLinks() throws {
        let hex = String(repeating: "a", count: 64)
        XCTAssertNotNil(MessageLink(url: URL(string: "gitkittie-mail://message/acct-work/m-\(hex)")!))
        XCTAssertNotNil(MessageLink(url: URL(string: "GITKITTIE-MAIL://Message/ACCT-work/F-\(hex.uppercased())")!))
        for bad in [
            "https://message/acct-work/m-\(hex)",                 // another scheme
            "gitkittie-mail://thread/acct-work/m-\(hex)",          // another kind
            "gitkittie-mail://message/acct-work/x-\(hex)",         // unknown key
            "gitkittie-mail://message/acct-work/m-\(hex.dropLast())", // short hash
            "gitkittie-mail://message/acct-work/m-\(String(repeating: "g", count: 64))", // not hex
            "gitkittie-mail://message/m-\(hex)",                   // no account
            "gitkittie-mail://message/acct-work/m-\(hex)/more",    // extra part
            "gitkittie-mail://message/..%2Fetc/m-\(hex)",          // not an account id
            "gitkittie-mail://message/acct_work/m-\(hex)",
        ] {
            XCTAssertNil(MessageLink(url: URL(string: bad)!), bad)
        }
    }

    // MARK: Survives

    /// The same link before and after an index rebuild opens the same message.
    func testALinkSurvivesAnIndexRebuild() async throws {
        let store = try await MailStore.open(locations("a"))
        let id = try await store.ingest(invoice, account: work).id
        let noteID = try await store.ingest(note, account: work).id
        let link = try await makeLink(store, id)
        let noteLink = try await makeLink(store, noteID)
        guard case .content = noteLink.key else { return XCTFail("no Message-ID: named by content, \(noteLink)") }

        try await store.rebuildIndex()
        let rebuiltID = try await store.resolve(link)
        let rebuiltNote = try await store.resolve(noteLink)
        XCTAssertEqual(rebuiltID, id)
        XCTAssertEqual(rebuiltNote, noteID)
        let again = try await store.link(to: id)
        XCTAssertEqual(again, link)
    }

    /// The mail downloaded afresh into a new folder (another device, or the account synced
    /// from scratch) has new local ids; the link made before still finds it.
    func testALinkSurvivesAFreshDownload() async throws {
        let first = try await MailStore.open(locations("a"))
        let id = try await first.ingest(invoice, account: work).id
        let noteID = try await first.ingest(note, account: work).id
        let link = try await makeLink(first, id)
        let noteLink = try await makeLink(first, noteID)

        let fresh = try await MailStore.open(locations("b"))
        _ = try await fresh.ingest(SyntheticMail.plain(subject: "Something else", messageID: "other@example.com", body: "Other."), account: work)
        let freshID = try await fresh.ingest(invoice, account: work).id
        let freshNote = try await fresh.ingest(note, account: work).id
        XCTAssertNotEqual(freshID, id, "a new local id")
        let resolved = try await fresh.resolve(link)
        let resolvedNote = try await fresh.resolve(noteLink)
        XCTAssertEqual(resolved, freshID)
        XCTAssertEqual(resolvedNote, freshNote)
    }

    /// The link's account is gone (removed and added again: a new account id); the message is
    /// found in the account that has it now.
    func testALinkWhoseAccountIsGoneLooksInEveryAccount() async throws {
        let first = try await MailStore.open(locations("a"))
        let link = try await makeLink(first, try await first.ingest(invoice, account: work).id)

        let readded = try await MailStore.open(locations("b"))
        let id = try await readded.ingest(invoice, account: home).id
        let resolved = try await readded.resolve(link)
        XCTAssertEqual(resolved, id)
    }

    /// In its own account first: the same message in two accounts opens the link's copy.
    func testTheLinksOwnAccountWins() async throws {
        let store = try await MailStore.open(locations("a"))
        _ = try await store.ingest(invoice, account: home)
        let inWork = try await store.ingest(invoice, account: work).id
        let link = try await makeLink(store, inWork)
        let resolved = try await store.resolve(link)
        XCTAssertEqual(resolved, inWork)
    }

    /// A message this store does not have is not found, and nothing else is opened instead.
    func testALinkToAMessageNotHereFindsNothing() async throws {
        let store = try await MailStore.open(locations("a"))
        _ = try await store.ingest(note, account: work)
        let other = MessageLink(account: work, messageID: "missing@example.com", fingerprint: "")
        let resolved = try await store.resolve(other)
        XCTAssertNil(resolved)
        let unknown = try await store.link(to: MailMessageID())
        XCTAssertNil(unknown)
    }
}
