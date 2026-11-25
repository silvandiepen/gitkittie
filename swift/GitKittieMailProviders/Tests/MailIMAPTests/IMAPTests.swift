import Foundation
import MailProvider
import NIOCore
import NIOIMAP
import XCTest
@testable import MailIMAP

final class IMAPMappingTests: XCTestCase {
    func testFolderRolesFromSpecialUseAndNames() {
        XCTAssertEqual(FolderRoles.role(id: "INBOX", displayName: "INBOX", attributes: []), .inbox)
        XCTAssertEqual(FolderRoles.role(id: "Foo", displayName: "Foo", attributes: ["\\sent"]), .sent)
        XCTAssertEqual(FolderRoles.role(id: "Sent Messages", displayName: "Sent Messages", attributes: []), .sent)
        XCTAssertEqual(FolderRoles.role(id: "Deleted Messages", displayName: "Deleted Messages", attributes: []), .trash)
        XCTAssertEqual(FolderRoles.role(id: "[Gmail]/All Mail", displayName: "All Mail", attributes: ["\\all"]), .all)
        XCTAssertNil(FolderRoles.role(id: "Projects", displayName: "Projects", attributes: []))
    }

    func testFlagsRoundTrip() {
        let flags = MessageFlags(seen: true, flagged: true, keywords: ["$Forwarded"])
        let imap = IMAPSession.imapFlags(flags)
        XCTAssertEqual(IMAPSession.messageFlags(imap + [Flag("\\Recent")]), flags)
    }

    func testMessageIDNormalisation() {
        XCTAssertEqual(MessageIDs.normalize(" <a.b@example.com> "), "a.b@example.com")
        XCTAssertEqual(MessageIDs.normalize("a.b@example.com"), "a.b@example.com")
    }

    func testXOAUTH2InitialResponse() {
        XCTAssertEqual(String(decoding: SASL.xoauth2(username: "u@example.com", accessToken: "tok"), as: UTF8.self),
                       "user=u@example.com\u{1}auth=Bearer tok\u{1}\u{1}")
    }

    func testModifiedUTF7FolderNamesDecode() throws {
        let path = try MailboxPath(name: MailboxName(Array("Projects/Caf&AOk-".utf8)), pathSeparator: "/")
        let folder = IMAPSession.folder(from: MailboxInfo(attributes: [], path: path, extensions: [:]))
        XCTAssertEqual(folder.id, "Projects/Caf&AOk-")
        XCTAssertEqual(folder.path, ["Projects", "Café"])
        XCTAssertTrue(folder.isSelectable)
    }

    func testServerSearchKeyNeedsEveryWordAndPersonAndNeverListsEverything() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day = utc.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 23))!
        let key = IMAPSession.searchKey(RemoteSearchCriteria(terms: ["invoice", "march"], participants: ["grace"],
                                                             receivedOnOrAfter: day, unreadOnly: true))
        guard case .and(let keys) = key else { return XCTFail("\(key)") }
        XCTAssertEqual(keys.count, 5)
        let text = ByteBuffer(string: "invoice")
        XCTAssertEqual(keys[0], .or(.subject(text), .or(.from(text), .text(text))))
        let person = ByteBuffer(string: "grace")
        XCTAssertEqual(keys[2], .or(.or(.from(person), .header("From", person)),
                                    .or(.or(.to(person), .header("To", person)), .or(.cc(person), .header("Cc", person)))))
        XCTAssertEqual(keys[3], .since(IMAPCalendarDay(year: 2026, month: 3, day: 4)!), "the UTC day")
        XCTAssertEqual(keys[4], .unseen)
        XCTAssertEqual(IMAPSession.searchKey(RemoteSearchCriteria(terms: ["one"])),
                       .or(.subject(ByteBuffer(string: "one")), .or(.from(ByteBuffer(string: "one")), .text(ByteBuffer(string: "one")))))
        XCTAssertTrue(RemoteSearchCriteria(unreadOnly: true).hasNoText, "a search without words is not sent")
    }

    func testIMAPRefusesSTARTTLSAndRemotePlaintext() async {
        let credential = MailCredential.password(username: "u", password: Secret("p"))
        for endpoint in [ServerEndpoint(host: "imap.example.com", port: 143, security: .startTLS),
                         ServerEndpoint(host: "imap.example.com", port: 143, security: .plaintextLoopbackOnly)] {
            do {
                try await IMAPConnector(endpoint: endpoint, credential: credential).withSession { _ in }
                XCTFail("must refuse \(endpoint)")
            } catch {
                guard case .unsupported = error as? MailProviderError else { return XCTFail("\(error)") }
            }
        }
    }
}
