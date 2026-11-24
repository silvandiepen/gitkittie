import XCTest
import MailCore
import MailTestSupport
@testable import MailStore

/// The store's crash and rebuild guarantees, run over the GKM-003 fixture corpus and the
/// hostile-HTML fixtures (malformed MIME, hostile names, duplicate ids, nesting bombs) rather
/// than only the small synthetic set.
final class FixtureCorpusStoreTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let account = MailAccountID("corpus")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("corpus-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func corpus() throws -> [(name: String, data: Data)] {
        try (MailFixtures.messageURLs() + MailFixtures.hostileHTMLURLs()).map { ($0.lastPathComponent, try Data(contentsOf: $0)) }
    }

    func testEveryFixtureIsStoredAndReadBackByteForByte() async throws {
        let store = try await MailStore.open(locations)
        for fixture in try corpus() {
            let id = try await store.ingest(fixture.data, account: account).id
            let original = try await store.originalData(of: id)
            XCTAssertEqual(original, fixture.data, fixture.name)
            let stored = try await store.message(id)
            XCTAssertFalse(stored.markdown.contains("<script"), "\(fixture.name): no live HTML in the Markdown")
            for attachment in stored.front.attachments {
                XCTAssertFalse(attachment.fileName.contains("/") || attachment.fileName.hasPrefix("."), "\(fixture.name): \(attachment.fileName)")
            }
        }
        let failed = try await store.verifyIntegrity()
        XCTAssertEqual(failed, [])
    }

    /// For every point a write can stop at, with each attachment-carrying fixture as the
    /// interrupted message: all or nothing, nothing temporary left, the rest untouched.
    func testAKilledWriteNeverLeavesAHalfMessageOverTheCorpus() async throws {
        let all = try corpus()
        let targets = ["mal-path-traversal-filenames.eml", "txn-invoice-nl.eml", "lookalike-links.eml"]
        let steps: [(String, @Sendable (WriteStep) -> Bool, Bool)] = [
            ("journal", { if case .beforeRename(let name) = $0 { return name.hasSuffix(".json") }; return false }, false),
            ("blob", { if case .beforeRename(let name) = $0 { return name.count == 64 }; return false }, false),
            ("markdown", { if case .beforeRename(let name) = $0 { return name.hasSuffix(".md") }; return false }, false),
            ("original", { if case .beforeRename(let name) = $0 { return name.hasSuffix(".eml") }; return false }, false),
            ("index", { $0 == .beforeIndex }, true),
        ]
        for target in targets {
            let interrupted = try XCTUnwrap(all.first { $0.name == target })
            let others = all.filter { $0.name != target }
            for (name, matches, survives) in steps {
                try? FileManager.default.removeItem(at: root)
                var kept: [MailMessageID] = []
                do {
                    let store = try await MailStore.open(locations)
                    for (offset, fixture) in others.enumerated() {
                        kept.append(try await store.ingest(fixture.data, account: account,
                                                           remote: RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: UInt32(offset + 1))).id)
                    }
                }
                let remote = RemoteLocation(mailbox: "INBOX", uidValidity: 1, uid: 9_999)
                do {
                    let crashing = try await MailStore.open(locations, faults: WriteFaults { if matches($0) { throw Kill() } })
                    await XCTAssertThrowsErrorAsync(try await crashing.ingest(interrupted.data, account: account, remote: remote), "\(target) \(name)")
                }
                let store = try await MailStore.open(locations)
                let count = try await store.messageCount()
                XCTAssertEqual(count, others.count + (survives ? 1 : 0), "\(target) at \(name)")
                let mapped = try await store.localID(at: remote, account: account)
                XCTAssertEqual(mapped != nil, survives, "\(target) at \(name)")
                if let mapped {
                    let folders = try await store.search(SearchQuery(mailbox: "INBOX")).contains { $0.id == mapped }
                    XCTAssertTrue(folders, "\(target) at \(name): the recovered message is in its folder")
                }
                let partials = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter {
                    $0.hasSuffix(AtomicWriter.partialSuffix) || $0.contains("state/journal/") && $0.hasSuffix(".json")
                }
                XCTAssertEqual(partials, [], "\(target) at \(name)")
                let failed = try await store.verifyIntegrity()
                XCTAssertEqual(failed, [], "\(target) at \(name)")
                for id in kept.prefix(3) { _ = try await store.originalData(of: id) }
            }
        }
    }

    func testARebuildGivesIdenticalResultsOverTheCorpus() async throws {
        let queries = ["rechnung", "invoice", "password", "cloudvault", "slides", "verification code", "zzz", "storage report", "köln"]
        var before: [[MailMessageID]] = []
        var listBefore: [MessageSummary] = []
        do {
            let store = try await MailStore.open(locations)
            for fixture in try corpus() { try await store.ingest(fixture.data, account: account, receivedAt: Date(timeIntervalSince1970: 1_795_600_000)) }
            for query in queries { before.append(try await store.search(query).map(\.id)) }
            listBefore = try await store.search(SearchQuery(), limit: 1_000)
        }
        XCTAssertFalse(before[3].isEmpty)
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: locations.indexURL.path + suffix) }
        let rebuilt = try await MailStore.open(locations)
        var after: [[MailMessageID]] = []
        for query in queries { after.append(try await rebuilt.search(query).map(\.id)) }
        XCTAssertEqual(after, before)
        let listAfter = try await rebuilt.search(SearchQuery(), limit: 1_000)
        XCTAssertEqual(listAfter, listBefore)
    }

    /// A `.md` written by an older parser (or edited by hand) is rewritten from its `.eml` on
    /// rebuild; one that already matches is left alone (same bytes, same modification date).
    func testRebuildRewritesMarkdownThatDiffersAndLeavesTheRest() async throws {
        let store = try await MailStore.open(locations)
        let html = try await store.ingest(try MailFixtures.message("promo-sale-en.eml"), account: account).id
        let plain = try await store.ingest(try MailFixtures.message("conv-personal-en-dinner.eml"), account: account).id
        let htmlURL = try await store.message(html).markdownURL
        let plainURL = try await store.message(plain).markdownURL
        let current = try String(contentsOf: htmlURL, encoding: .utf8)
        // What the provisional parser used to write for an HTML-only message.
        let stale = current.replacingOccurrences(of: #"(?s)\n# .*"#, with: "\n# Old\n\n_This message has only an HTML body._\n", options: .regularExpression)
        try Data(stale.utf8).write(to: htmlURL)
        let plainDate = try FileManager.default.attributesOfItem(atPath: plainURL.path)[.modificationDate] as? Date

        try await store.rebuildIndex()
        XCTAssertEqual(try String(contentsOf: htmlURL, encoding: .utf8), current)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: plainURL.path)[.modificationDate] as? Date, plainDate)
    }

    private struct Kill: Error {}
}
