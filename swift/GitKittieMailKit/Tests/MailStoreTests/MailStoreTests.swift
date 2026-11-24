import XCTest
import MailCore
import MailTestSupport
@testable import MailStore

final class MailStoreTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let account = MailAccountID("acct-1")
    private let received = Date(timeIntervalSince1970: 1_795_600_000.7)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mailstore-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFixturesAreBundled() throws {
        XCTAssertNotNil(MailFixtures.directory)
    }

    // MARK: Layout

    func testIngestWritesTheOriginalUntouchedAndDerivedMarkdownBesideIt() async throws {
        let store = try await MailStore.open(locations)
        let eml = SyntheticMail.corpus[0]
        let result = try await store.ingest(eml, account: account, receivedAt: received)
        XCTAssertTrue(result.isNew)

        let stored = try await store.message(result.id)
        // Date: Tue, 24 Nov 2026 10:15 +0100 → filed under 2026/11.
        XCTAssertEqual(stored.emlURL.path, locations.mailFolder.appendingPathComponent("accounts/acct-1/messages/2026/11/\(result.id).eml").path)
        XCTAssertEqual(try Data(contentsOf: stored.emlURL), eml, "the original is stored byte for byte")
        let front = stored.front
        XCTAssertEqual(front.id, result.id)
        XCTAssertEqual(front.messageId, "inv-114@example.com")
        XCTAssertEqual(front.subject, "Invoice 2026-114 for November")
        XCTAssertEqual(front.from, [MailAddress(name: "Ada Example", address: "ada@example.com")])
        XCTAssertEqual(front.to, [MailAddress(address: "bo@example.org")])
        XCTAssertEqual(front.received, Date(timeIntervalSince1970: 1_795_600_000))
        XCTAssertEqual(front.emlSha256, Hashing.sha256Hex(eml))
        XCTAssertEqual(front.emlSize, eml.count)
        XCTAssertTrue(stored.markdown.hasPrefix("---\nschema: 1\nid: \"\(result.id)\"\n"))
        XCTAssertTrue(stored.body.contains("# Invoice 2026-114 for November"))
        XCTAssertTrue(stored.body.contains("The invoice for November is attached in the portal."))
        XCTAssertEqual(stored.textBody, "Hello Bo,\nThe invoice for November is attached in the portal.\nRegards, Ada\n")
        let value1 = try await store.originalData(of: result.id)
        XCTAssertEqual(value1, eml)
    }

    func testThreadHeadersAreKeptForTheThreadGraph() async throws {
        let store = try await MailStore.open(locations)
        let reply = try await store.ingest(SyntheticMail.corpus[2], account: account, receivedAt: received)
        let front = try await store.message(reply.id).front
        XCTAssertEqual(front.inReplyTo, ["inv-114@example.com"])
        XCTAssertEqual(front.references, ["inv-114@example.com"])
    }

    func testAttachmentsAreStoredOnceByHash() async throws {
        let store = try await MailStore.open(locations)
        let pdf = Data("%PDF-1.4 the same bytes twice".utf8)
        let first = try await store.ingest(SyntheticMail.withAttachment(subject: "One", messageID: "one@example.com", body: "First",
                                                                        fileName: "../../outside.pdf", attachment: pdf), account: account)
        let second = try await store.ingest(SyntheticMail.withAttachment(subject: "Two", messageID: "two@example.com", body: "Second",
                                                                         fileName: "copy.pdf", attachment: pdf), account: account)
        let blobs = try FileManager.default.contentsOfDirectory(atPath: locations.mailFolder.appendingPathComponent("blobs").path)
        XCTAssertEqual(blobs, [Hashing.sha256Hex(pdf)])

        let reference = try await XCTUnwrapAsync(try await store.message(first.id).front.attachments.first)
        XCTAssertEqual(reference.fileName, "_.._outside.pdf", "a sender's file name is display text, never a path")
        let value2 = try await store.attachmentData(reference)
        XCTAssertEqual(value2, pdf)
        let value3 = try await store.message(second.id).front.attachments.first?.blob
        XCTAssertEqual(value3, reference.blob)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.pdf").path))
    }

    func testNothingDeviceLocalIsWrittenInsideTheMailFolder() async throws {
        let store = try await MailStore.open(locations)
        try await store.save(MailAccount(id: account, displayName: "Ada", address: "ada@example.com"))
        for (offset, eml) in SyntheticMail.corpus.enumerated() {
            try await store.ingest(eml, account: account, remote: RemoteLocation(mailbox: "INBOX", uidValidity: 7, uid: UInt32(offset + 1)))
        }
        _ = try await store.search("invoice")
        try await store.rebuildIndex()

        let files = try allFiles(under: locations.mailFolder)
        for file in files {
            let allowed = file == "layout.json"
                || file.range(of: #"^accounts/acct-1/account\.json$"#, options: .regularExpression) != nil
                || file.range(of: #"^accounts/acct-1/messages/\d{4}/\d{2}/[0-9a-f-]{36}\.(eml|md)$"#, options: .regularExpression) != nil
                || file.range(of: #"^blobs/[0-9a-f]{64}$"#, options: .regularExpression) != nil
            XCTAssertTrue(allowed, "unexpected file in the mail folder: \(file)")
        }
        XCTAssertEqual(files.filter { $0.hasSuffix(".eml") }.count, SyntheticMail.corpus.count)
        let device = try allFiles(under: locations.deviceFolder)
        XCTAssertTrue(device.contains("index.sqlite"))
        XCTAssertTrue(device.contains("state/acct-1/sync.sqlite"))
    }

    func testTheDeviceFolderMayNotSitInsideTheMailFolder() async throws {
        let nested = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Mail/.state"))
        await XCTAssertThrowsErrorAsync(try await MailStore.open(nested)) { XCTAssertEqual($0 as? MailStoreError, .deviceStateInsideMailFolder) }
        let around = StoreLocations(mailFolder: root.appendingPathComponent("Support/Mail/Mine"), deviceFolder: root.appendingPathComponent("Support"))
        await XCTAssertThrowsErrorAsync(try await MailStore.open(around)) { XCTAssertEqual($0 as? MailStoreError, .deviceStateInsideMailFolder) }
    }

    func testUnsafeAccountIDsAreRefused() async throws {
        let store = try await MailStore.open(locations)
        for bad in ["../escape", "a/b", ".hidden", "", String(repeating: "x", count: 65)] {
            await XCTAssertThrowsErrorAsync(try await store.ingest(SyntheticMail.corpus[0], account: MailAccountID(bad))) {
                XCTAssertEqual($0 as? MailStoreError, .unsafePathComponent(bad))
            }
        }
        XCTAssertEqual(try allFiles(under: locations.mailFolder), ["layout.json"])
    }

    func testANewerFolderLayoutIsRefused() async throws {
        try FileManager.default.createDirectory(at: locations.mailFolder, withIntermediateDirectories: true)
        try Data(#"{"layoutVersion": 99}"#.utf8).write(to: locations.mailFolder.appendingPathComponent("layout.json"))
        await XCTAssertThrowsErrorAsync(try await MailStore.open(locations)) { XCTAssertEqual($0 as? MailStoreError, .unsupportedLayoutVersion(99)) }
    }

    func testAccountsAreReadFromTheFolder() async throws {
        let store = try await MailStore.open(locations)
        let value4 = try await store.accounts()
        XCTAssertEqual(value4, [])
        let ada = MailAccount(id: account, displayName: "Ada at Example", address: "ada@example.com")
        try await store.save(ada)
        let value5 = try await store.accounts()
        XCTAssertEqual(value5, [ada])
    }

    // MARK: Identity

    func testTheSameRemoteMessageIsStoredOnce() async throws {
        let store = try await MailStore.open(locations)
        let location = RemoteLocation(mailbox: "INBOX", uidValidity: 42, uid: 7)
        let first = try await store.ingest(SyntheticMail.corpus[0], account: account, remote: location)
        let again = try await store.ingest(SyntheticMail.corpus[0], account: account, remote: location)
        XCTAssertEqual(again, IngestResult(id: first.id, isNew: false))
        let value6 = try await store.messageCount()
        XCTAssertEqual(value6, 1)
        let value7 = try await store.localID(at: location, account: account)
        XCTAssertEqual(value7, first.id)
        let value8 = try await store.remoteLocations(of: first.id, account: account)
        XCTAssertEqual(value8, [location])
        let value9 = try await store.mailboxes(account: account)
        XCTAssertEqual(value9, ["INBOX"])
    }

    func testAUIDValidityResetVoidsOldUIDsAndOffersReconciliationCandidates() async throws {
        let store = try await MailStore.open(locations)
        let inbox = RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 10)
        let archive = RemoteLocation(mailbox: "Archive", uidValidity: 5, uid: 3)
        let invoice = try await store.ingest(SyntheticMail.corpus[0], account: account, remote: inbox)
        let news = try await store.ingest(SyntheticMail.corpus[3], account: account, remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 11))
        try await store.record(archive, for: news.id, account: account)

        let value10 = try await store.updateUIDValidity(1, mailbox: "INBOX", account: account)
        XCTAssertEqual(value10, [], "same UIDVALIDITY: nothing changes")
        let orphaned = try await store.updateUIDValidity(2, mailbox: "INBOX", account: account)
        XCTAssertEqual(orphaned, [invoice.id], "the newsletter still has its Archive location")
        let value11 = try await store.localID(at: inbox, account: account)
        XCTAssertNil(value11)
        let value12 = try await store.remoteLocations(of: news.id, account: account)
        XCTAssertEqual(value12, [archive])

        // Same Message-ID, or no Message-ID but the same content: candidates, not merges.
        let value13 = try await store.reconciliationCandidates(for: SyntheticMail.corpus[0], account: account)
        XCTAssertEqual(value13, [invoice.id])
        let noID = try await store.ingest(SyntheticMail.corpus[5], account: account)
        let value14 = try await store.reconciliationCandidates(for: SyntheticMail.corpus[5], account: account)
        XCTAssertEqual(value14, [noID.id])
        let value15 = try await store.reconciliationCandidates(for: SyntheticMail.corpus[5], account: MailAccountID("other"))
        XCTAssertEqual(value15, [])
    }

    func testLocalIDsAreUniqueEvenForIdenticalMessages() async throws {
        let store = try await MailStore.open(locations)
        let a = try await store.ingest(SyntheticMail.corpus[0], account: account)
        let b = try await store.ingest(SyntheticMail.corpus[0], account: account)
        XCTAssertNotEqual(a.id, b.id, "a duplicate Message-ID is a signal, not the same identity")
        let value16 = try await store.messageCount()
        XCTAssertEqual(value16, 2)
    }

    // MARK: Crash safety

    /// For every point a write can stop at, over the whole corpus: the interrupted message is
    /// either entirely there (`.eml`, `.md`, index, mapping) or entirely absent, nothing
    /// temporary is left, and the messages stored before it are untouched.
    func testAKilledWriteNeverLeavesAHalfMessage() async throws {
        let steps: [(String, @Sendable (WriteStep) -> Bool, Bool)] = [
            ("journal", { if case .beforeRename(let name) = $0 { return name.hasSuffix(".json") }; return false }, false),
            ("blob", { if case .beforeRename(let name) = $0 { return name.count == 64 }; return false }, false),
            ("markdown", { if case .beforeRename(let name) = $0 { return name.hasSuffix(".md") }; return false }, false),
            ("original", { if case .beforeRename(let name) = $0 { return name.hasSuffix(".eml") }; return false }, false),
            ("index", { $0 == .beforeIndex }, true),
        ]
        for (name, matches, survives) in steps {
            try? FileManager.default.removeItem(at: root)
            let corpus = SyntheticMail.corpus
            let target = corpus.count - 1 // the message with an attachment, so every step happens
            var kept: [MailMessageID] = []
            do {
                let store = try await MailStore.open(locations)
                for (offset, eml) in corpus.dropLast().enumerated() {
                    kept.append(try await store.ingest(eml, account: account, remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: UInt32(offset + 1))).id)
                }
            }
            let remote = RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 99)
            do {
                let crashing = try await MailStore.open(locations, faults: WriteFaults { step in
                    if matches(step) { throw SimulatedKill() }
                })
                await XCTAssertThrowsErrorAsync(try await crashing.ingest(corpus[target], account: account, remote: remote), "step \(name)")
            }

            let store = try await MailStore.open(locations)
            let files = try allFiles(under: locations.mailFolder) + allFiles(under: locations.deviceFolder)
            XCTAssertFalse(files.contains { $0.hasSuffix(AtomicWriter.partialSuffix) }, "\(name): temporary files left: \(files)")
            XCTAssertFalse(files.contains { $0.hasPrefix("state/journal/") }, "\(name): journal not cleared")
            let originals = files.filter { $0.hasSuffix(".eml") }.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".eml", with: "") }
            let markdown = files.filter { $0.hasSuffix(".md") }.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "") }
            XCTAssertEqual(Set(originals), Set(markdown), "\(name): every .eml has its .md and no .md is alone")
            XCTAssertEqual(originals.count, corpus.count - (survives ? 0 : 1), "step \(name)")
            let value17 = try await store.messageCount()
            XCTAssertEqual(value17, originals.count, "step \(name)")

            let found = try await store.search("plan.pdf").map(\.id)
            let mapped = try await store.localID(at: remote, account: account)
            if survives {
                XCTAssertNotNil(mapped, "\(name): the stored message gets its remote mapping on recovery")
                XCTAssertTrue(found.contains(try XCTUnwrap(mapped)), "\(name): the recovered message is searchable")
                let value18 = try await store.message(try XCTUnwrap(mapped)).front.attachments.count
                XCTAssertEqual(value18, 1)
            } else {
                XCTAssertNil(mapped, "step \(name)")
                XCTAssertTrue(found.isEmpty, "step \(name)")
            }
            for id in kept { let data = try await store.originalData(of: id); XCTAssertFalse(data.isEmpty) }
            let value19 = try await store.verifyIntegrity()
            XCTAssertEqual(value19, [], "step \(name)")
        }
    }

    // MARK: Rebuild

    func testARebuiltIndexGivesIdenticalSearchResults() async throws {
        let queries = ["invoice", "november invoice", "garden", "café", "cafe", "ada", "example.org", "receipt", "plan.pdf", "stable local", "zzz"]
        var before: [[MailMessageID]] = []
        var listBefore: [MessageSummary] = []
        do {
            let store = try await MailStore.open(locations)
            for eml in SyntheticMail.corpus { try await store.ingest(eml, account: account, receivedAt: received) }
            for query in queries { before.append(try await store.search(query).map(\.id)) }
            listBefore = try await store.summaries()
        }
        XCTAssertEqual(before[0].count, 3)
        XCTAssertEqual(before[3], before[4], "diacritics are folded")
        XCTAssertEqual(before[3].count, 1)
        XCTAssertEqual(before.last, [])

        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: locations.indexURL.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        let rebuilt = try await MailStore.open(locations)
        var after: [[MailMessageID]] = []
        for query in queries { after.append(try await rebuilt.search(query).map(\.id)) }
        XCTAssertEqual(after, before)
        let value20 = try await rebuilt.summaries()
        XCTAssertEqual(value20, listBefore)

        try await rebuilt.rebuildIndex()
        var again: [[MailMessageID]] = []
        for query in queries { again.append(try await rebuilt.search(query).map(\.id)) }
        XCTAssertEqual(again, before)
    }

    func testRebuildRestoresAMissingMarkdownFileAndRemovesAnOrphan() async throws {
        let store = try await MailStore.open(locations)
        let id = try await store.ingest(SyntheticMail.corpus[1], account: account, receivedAt: received).id
        let stored = try await store.message(id)
        try FileManager.default.removeItem(at: stored.markdownURL)
        let orphan = stored.markdownURL.deletingLastPathComponent().appendingPathComponent("\(MailMessageID()).md")
        try Data("---\n---\n".utf8).write(to: orphan)

        try await store.rebuildIndex()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        let restored = try await store.message(id)
        XCTAssertEqual(restored.front.messageId, "receipt-9@example.org")
        // The received date is gone with the .md; the Date header stands in for it.
        XCTAssertEqual(restored.front.received, restored.front.date)
    }

    func testADamagedIndexIsReplacedAndRebuilt() async throws {
        do {
            let store = try await MailStore.open(locations)
            for eml in SyntheticMail.corpus { try await store.ingest(eml, account: account) }
        }
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: locations.indexURL.path + suffix) }
        try Data("this is not a database".utf8).write(to: locations.indexURL)
        let store = try await MailStore.open(locations)
        let value21 = try await store.messageCount()
        XCTAssertEqual(value21, SyntheticMail.corpus.count)
        let value22 = try await store.search("weekly garden").count
        XCTAssertEqual(value22, 1)
    }

    func testAChangedOriginalIsReportedNotRepaired() async throws {
        let store = try await MailStore.open(locations)
        let id = try await store.ingest(SyntheticMail.corpus[0], account: account).id
        let url = try await store.message(id).emlURL
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count - 3] ^= 0x01
        try bytes.write(to: url)
        let value23 = try await store.verifyIntegrity()
        XCTAssertEqual(value23, [id])
        await XCTAssertThrowsErrorAsync(try await store.originalData(of: id)) {
            guard case .integrityMismatch = $0 as? MailStoreError else { return XCTFail("\($0)") }
        }
    }

    // MARK: Helpers

    private struct SimulatedKill: Error {}

    /// Every regular file under `folder`, as paths relative to it, sorted.
    private func allFiles(under folder: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents.count
        var files: [String] = []
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            files.append(url.resolvingSymlinksInPath().standardizedFileURL.pathComponents.dropFirst(base).joined(separator: "/"))
        }
        return files.sorted()
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ message: String = "",
                                  file: StaticString = #filePath, line: UInt = #line,
                                  _ handler: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error. \(message)", file: file, line: line)
    } catch {
        handler(error)
    }
}

func XCTUnwrapAsync<T>(_ expression: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value, file: file, line: line)
}
