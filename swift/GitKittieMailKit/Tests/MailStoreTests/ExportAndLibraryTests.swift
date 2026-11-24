import XCTest
import MailCore
@testable import MailStore

/// Export (GKM-023): originals out byte for byte, Markdown beside them, no device state; and the
/// attachment library's filters.
final class ExportAndLibraryTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private var destination: URL!
    private let work = MailAccountID("acct-work")
    private let home = MailAccountID("acct-home")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
        destination = root.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let pdf = Data("%PDF-1.4 synthetic quote".utf8)
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])

    @discardableResult
    private func seed(_ store: MailStore) async throws -> [String: MailMessageID] {
        let connection = MailConnectionSettings(
            kind: .imap,
            imap: MailServerSettings(host: "imap.example.com", port: 993, security: .implicitTLS, username: "ada"),
            smtp: MailServerSettings(host: "smtp.example.com", port: 587, security: .startTLS, username: "ada@example.com"))
        try await store.save(MailAccount(id: work, displayName: "Work", address: "ada@example.com", connection: connection))
        try await store.save(MailAccount(id: home, displayName: "Home", address: "ada@example.org"))
        var ids: [String: MailMessageID] = [:]
        ids["quote"] = try await store.ingest(SyntheticMail.withAttachment(subject: "Quote", messageID: "quote@example.net", body: "Quote attached.",
                                                                           fileName: "quote.pdf", attachment: pdf),
                                              account: work, remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 1),
                                              flags: MessageFlags(seen: true, flagged: true)).id
        ids["photo"] = try await store.ingest(SyntheticMail.withAttachment(subject: "Photo", messageID: "photo@example.net", body: "A photo.",
                                                                           fileName: "site", attachment: png, mediaType: "image/png",
                                                                           date: "Sun, 1 Nov 2026 08:00:00 +0000"), account: home).id
        ids["invoice"] = try await store.ingest(SyntheticMail.plain(subject: "Invoice 7", messageID: "inv7@example.com", body: "Invoice."),
                                                account: work).id
        ids["reply"] = try await store.ingest(SyntheticMail.plain(from: "Bo Example <bo@example.org>", subject: "Re: Invoice 7",
                                                                  date: "Tue, 24 Nov 2026 12:00:00 +0000", messageID: "re7@example.org",
                                                                  inReplyTo: "inv7@example.com", body: "Paid."), account: work).id
        return ids
    }

    private func files(under folder: URL) -> [String] {
        let rootPath = folder.standardizedFileURL.path
        var result: [String] = []
        for case let url as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [])! {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if !isDirectory.boolValue { result.append(String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))) }
        }
        return result.sorted()
    }

    // MARK: Round trip

    /// Export, re-import into a fresh store, compare bytes: what any `.eml` reader (Apple Mail
    /// included) gets is exactly what the provider sent.
    func testExportedOriginalsReimportIntoAFreshStoreByteForByte() async throws {
        let store = try await MailStore.open(locations)
        let ids = try await seed(store)
        let result = try await store.export(.account(work), to: destination)
        XCTAssertEqual(result.messages, 3)
        XCTAssertEqual(result.attachments, 1)
        XCTAssertEqual(result.folder.lastPathComponent, "Work Mail")

        let fresh = try await MailStore.open(StoreLocations(mailFolder: root.appendingPathComponent("Fresh/Mail"),
                                                            deviceFolder: root.appendingPathComponent("Fresh/Support")))
        let exported = files(under: result.folder).filter { $0.hasSuffix(".eml") }
        XCTAssertEqual(exported.count, 3)
        var reimported: [Data] = []
        for path in exported {
            let bytes = try Data(contentsOf: result.folder.appendingPathComponent(path))
            let id = try await fresh.ingest(bytes, account: MailAccountID("on-my-mac")).id
            reimported.append(try await fresh.originalData(of: id))
            // The exported file has the stored file's exact bytes, under the same name.
            let sourceID = try XCTUnwrap(MailMessageID((path as NSString).lastPathComponent.replacingOccurrences(of: ".eml", with: "")))
            let source = try await store.originalData(of: sourceID)
            XCTAssertEqual(bytes, source)
        }
        var originals: [Data] = []
        for key in ["quote", "invoice", "reply"] { originals.append(try await store.originalData(of: ids[key]!)) }
        XCTAssertEqual(Set(reimported), Set(originals), "export → import → the same bytes")

        // The Markdown copies came too, byte for byte, and their attachment links resolve.
        let quote = try await store.message(ids["quote"]!)
        let exportedMarkdown = result.folder.appendingPathComponent(files(under: result.folder).first { $0.hasSuffix("\(ids["quote"]!).md") }!)
        XCTAssertEqual(try Data(contentsOf: exportedMarkdown), try Data(contentsOf: quote.markdownURL))
        let link = try XCTUnwrap(quote.markdown.components(separatedBy: "](").dropFirst().first?.components(separatedBy: ")").first)
        let resolved = exportedMarkdown.deletingLastPathComponent().appendingPathComponent(link).standardizedFileURL
        XCTAssertEqual(try Data(contentsOf: resolved), pdf)
    }

    func testAnExportOpensAsAMailFolderOfItsOwn() async throws {
        let store = try await MailStore.open(locations)
        let ids = try await seed(store)
        let result = try await store.export(.account(work), to: destination)
        let opened = try await MailStore.open(StoreLocations(mailFolder: result.folder, deviceFolder: root.appendingPathComponent("Other/Support")))
        let count = try await opened.messageCount()
        XCTAssertEqual(count, 3)
        let original = try await store.originalData(of: ids["quote"]!)
        let copy = try await opened.originalData(of: ids["quote"]!)
        XCTAssertEqual(copy, original)
        let attachment = try await opened.message(ids["quote"]!).front.attachments.first!
        let bytes = try await opened.attachmentData(attachment)
        XCTAssertEqual(bytes, pdf)
        let failures = try await opened.verifyIntegrity()
        XCTAssertTrue(failures.isEmpty)
    }

    // MARK: No device-local state

    func testExportNeverCarriesDeviceState() async throws {
        let store = try await MailStore.open(locations)
        try await seed(store)
        try await store.recordAttachmentText("secret extracted text", forBlob: Hashing.sha256Hex(pdf))
        let result = try await store.export(.account(work), to: destination)

        for path in files(under: result.folder) {
            let allowed = path == "layout.json"
                || path.range(of: #"^accounts/acct-work/account\.json$"#, options: .regularExpression) != nil
                || path.range(of: #"^accounts/acct-work/messages/\d{4}/\d{2}/[0-9a-f-]{36}\.(eml|md)$"#, options: .regularExpression) != nil
                || path.range(of: #"^blobs/[0-9a-f]{64}$"#, options: .regularExpression) != nil
            XCTAssertTrue(allowed, "unexpected file in an export: \(path)")
        }
        let everything = try files(under: result.folder).map { try Data(contentsOf: result.folder.appendingPathComponent($0)) }
        XCTAssertFalse(everything.contains { String(decoding: $0, as: UTF8.self).contains("secret extracted text") })
        XCTAssertFalse(everything.contains { String(decoding: $0, as: UTF8.self).contains("SQLite format") })
        let account = try JSONSerialization.jsonObject(with: Data(contentsOf: result.folder.appendingPathComponent("accounts/acct-work/account.json"))) as? [String: Any]
        XCTAssertNil(account?["connection"], "no servers or user names in an export")
        XCTAssertEqual(account?["displayName"] as? String, "Work")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".Work Mail").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["Work Mail"], "no staging folder left")
    }

    // MARK: Selections

    func testMessageThreadAndSpaceExports() async throws {
        let store = try await MailStore.open(locations)
        let ids = try await seed(store)

        let single = try await store.export(.messages([ids["photo"]!]), to: destination)
        XCTAssertEqual(single.messages, 1)
        XCTAssertEqual(single.folder.lastPathComponent, "Photo")

        let threadID = try await store.search(SearchQuery(text: "invoice")).first!.threadID
        let thread = try await store.export(.thread(threadID), to: destination)
        XCTAssertEqual(thread.messages, 2)
        XCTAssertFalse(thread.folder.lastPathComponent.contains(":"), "named after the newest subject, made safe")
        XCTAssertTrue(thread.folder.lastPathComponent.hasSuffix("Invoice 7"))

        let space = try await store.createSpace(name: "Site")
        try await store.addMessages([ids["photo"]!, ids["quote"]!], to: space.id)
        try await store.removeMessages([ids["invoice"]!], from: space.id)
        let spaced = try await store.export(.space(space.id), to: destination)
        XCTAssertEqual(spaced.messages, 2)
        XCTAssertEqual(Set(files(under: spaced.folder).filter { $0.hasPrefix("accounts/") && $0.hasSuffix("account.json") }),
                       ["accounts/acct-home/account.json", "accounts/acct-work/account.json"], "a space spans accounts")
        let copied = try JSONCoding.decoder.decode(MailSpace.self, from: Data(contentsOf: spaced.folder.appendingPathComponent("spaces/\(space.id).json")))
        XCTAssertEqual(copied.memberIDs, [ids["photo"]!, ids["quote"]!])

        // The export reopens with its space.
        let opened = try await MailStore.open(StoreLocations(mailFolder: spaced.folder, deviceFolder: root.appendingPathComponent("S/Support")))
        let members = try await opened.search(SearchQuery(space: space.id))
        XCTAssertEqual(Set(members.map(\.id)), [ids["photo"]!, ids["quote"]!])

        // Exporting the same again never overwrites.
        let second = try await store.export(.messages([ids["photo"]!]), to: destination)
        XCTAssertEqual(second.folder.lastPathComponent, "Photo 2")
    }

    func testAChangedOriginalIsReportedNotExported() async throws {
        let store = try await MailStore.open(locations)
        let ids = try await seed(store)
        let url = try await store.message(ids["invoice"]!).emlURL
        try Data("tampered".utf8).write(to: url)
        let result = try await store.export(.account(work), to: destination)
        XCTAssertEqual(result.failed, [ids["invoice"]!])
        XCTAssertEqual(result.messages, 2)
        XCTAssertFalse(files(under: result.folder).contains { $0.contains(ids["invoice"]!.rawValue) })
    }

    func testAMissingDestinationIsRefused() async throws {
        let store = try await MailStore.open(locations)
        try await seed(store)
        do {
            try await store.export(.account(work), to: root.appendingPathComponent("Nowhere"))
            XCTFail("export needs an existing folder")
        } catch MailStoreError.exportDestinationUnavailable {}
    }

    // MARK: The attachment library

    func testTheLibraryListsAttachmentsAcrossAccountsWithFilters() async throws {
        let store = try await MailStore.open(locations)
        let ids = try await seed(store)
        let all = try await store.attachments()
        XCTAssertEqual(all.map(\.reference.fileName), ["quote.pdf", "site"], "newest message first")
        XCTAssertEqual(all.first?.message, ids["quote"]!)
        XCTAssertEqual(all.first?.reference.size, pdf.count)
        XCTAssertEqual(all.first?.from?.address, "cy@example.net")
        XCTAssertEqual(all.map(\.kind), [.pdf, .image])

        let pdfs = try await store.attachments(AttachmentQuery(kind: .pdf))
        XCTAssertEqual(pdfs.map(\.message), [ids["quote"]!])
        let images = try await store.attachments(AttachmentQuery(kind: .image))
        XCTAssertEqual(images.map(\.message), [ids["photo"]!], "by media type when the name has no extension")
        let other = try await store.attachments(AttachmentQuery(kind: .other))
        XCTAssertTrue(other.isEmpty)
        let homeOnly = try await store.attachments(AttachmentQuery(account: home))
        XCTAssertEqual(homeOnly.map(\.message), [ids["photo"]!])
        let bySender = try await store.attachments(AttachmentQuery(sender: "CY@EXAMPLE"))
        XCTAssertEqual(bySender.count, 2)
        let noSender = try await store.attachments(AttachmentQuery(sender: "bo"))
        XCTAssertTrue(noSender.isEmpty)
        let byName = try await store.attachments(AttachmentQuery(name: "quo"))
        XCTAssertEqual(byName.map(\.reference.fileName), ["quote.pdf"])
        let recent = try await store.attachments(AttachmentQuery(after: Date(timeIntervalSince1970: 1_795_000_000)))
        XCTAssertEqual(recent.map(\.message), [ids["quote"]!])
        let large = try await store.attachments(AttachmentQuery(minimumSize: 20))
        XCTAssertEqual(large.map(\.message), [ids["quote"]!])

        let space = try await store.createSpace(name: "Site")
        try await store.addMessages([ids["photo"]!], to: space.id)
        let inSpace = try await store.attachments(AttachmentQuery(space: space.id))
        XCTAssertEqual(inSpace.map(\.message), [ids["photo"]!])

        let totals = try await store.attachmentTotals()
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals.bytes, pdf.count + png.count)

        // What the library lists is what the store hands back, hash-checked.
        let bytes = try await store.attachmentData(all[0].reference)
        XCTAssertEqual(bytes, pdf)
    }

    func testAttachmentKinds() {
        XCTAssertEqual(AttachmentKind.of(mediaType: "application/octet-stream", fileName: "Budget.XLSX"), .spreadsheet)
        XCTAssertEqual(AttachmentKind.of(mediaType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", fileName: "x"), .document)
        XCTAssertEqual(AttachmentKind.of(mediaType: "text/calendar", fileName: "invite.ics"), .calendar)
        XCTAssertEqual(AttachmentKind.of(mediaType: "application/x-unknown", fileName: "data.bin"), .other)
    }
}
