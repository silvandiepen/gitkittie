import Foundation
import MailCore
import MailIMAP
import MailMIME
import MailProvider
import MailStore
import MailSync
import XCTest

/// Attachments on demand and pin for offline (GKM-036, MAIL-062/063) against the real local
/// mail server and a real store: what the sync leaves at the provider, what opening fetches, what
/// a pin keeps, what eviction gives back, and that a partial message is never taken for a
/// complete original (export, integrity, Reply/Forward's source).
final class OnDemandIntegrationTests: XCTestCase {
    private var server: TestMailServer!
    private var user: TestUser!
    private var captured: CapturedLog!
    private var root: URL!
    private var locations: StoreLocations!
    private var store: MailStore!
    private let account = MailAccountID("ondemand-test")
    /// Parts above 64 KB are left at the provider in these tests.
    private let options = SyncOptions(onDemandThreshold: 64 * 1024)

    override func setUp() async throws {
        server = try await TestMailServer.require()
        user = try await server.makeUser(function: name)
        captured = CapturedLog()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm-ondemand-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
        store = try await MailStore.open(locations)
    }

    override func tearDown() async throws {
        if let user, let captured { captured.assertNoSecret(user.rawPassword) }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Helpers

    private func imap(port: Int? = nil) -> IMAPConnector {
        IMAPConnector(endpoint: ServerEndpoint(host: "localhost", port: port ?? server.imapsPort, security: .implicitTLS, trust: server.trust),
                      credential: user.credential, log: captured.log, commandTimeout: .seconds(20))
    }

    private func sync(_ connector: IMAPConnector? = nil) async throws {
        try await SyncCoordinator(account: account, connector: connector ?? imap(), store: store, options: options, log: captured.log).syncOnce()
    }

    private func fetcher(_ connector: IMAPConnector? = nil) -> OnDemandFetcher {
        OnDemandFetcher(account: account, connector: connector ?? imap(), store: store, log: captured.log)
    }

    /// Deterministic bytes that do not compress or repeat (a fake photo or archive).
    private static func bytes(_ count: Int, seed: UInt64) -> Data {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        var data = Data(capacity: count)
        for _ in 0..<count {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            data.append(UInt8(truncatingIfNeeded: state))
        }
        return data
    }

    private struct Sample {
        var raw: Data
        var small: Data
        var photo: Data
        var archive: Data
    }

    /// A message with text and HTML, a 20 KB attachment and two large ones (300 KB and 200 KB).
    private func sample(_ subject: String, seed: UInt64) -> Sample {
        let me = MailAddress(name: "Ada Example", address: user.address)
        let small = Self.bytes(20 * 1024, seed: seed)
        let photo = Self.bytes(300 * 1024, seed: seed + 1)
        let archive = Self.bytes(200 * 1024, seed: seed + 2)
        let raw = MIMEBuilder(from: me, to: [me], subject: subject,
                              textBody: "The quarterly figures for \(subject) are attached.\n",
                              htmlBody: "<p>The quarterly figures for <b>\(subject)</b> are attached.</p>",
                              attachments: [OutgoingAttachment(filename: "notes.txt", mimeType: "application/octet-stream", data: small),
                                            OutgoingAttachment(filename: "photo.jpg", mimeType: "image/jpeg", data: photo),
                                            OutgoingAttachment(filename: "figures.zip", mimeType: "application/zip", data: archive)]).build()
        return Sample(raw: raw, small: small, photo: photo, archive: archive)
    }

    private func append(_ raws: [Data], to folder: String = "INBOX") async throws {
        try await imap().withSession { session in
            if folder != "INBOX", !(try await session.listFolders().contains { $0.id == folder }) {
                try await session.createFolder(folder)
            }
            for raw in raws { _ = try await session.append(raw, to: folder, flags: MailProvider.MessageFlags()) }
        }
    }

    private func onlyMessage() async throws -> MailMessageID {
        let all = try await store.summaries(account: account)
        XCTAssertEqual(all.count, 1)
        return try XCTUnwrap(all.first?.id)
    }

    private func attachments(_ id: MailMessageID) async throws -> [String: AttachmentReference] {
        let front = try await store.message(id).front
        return Dictionary(uniqueKeysWithValues: front.attachments.map { ($0.fileName, $0) })
    }

    private func sectionFetches() -> Int {
        captured.lines.filter { $0.contains("sections) in") && $0.contains("→") }.count
    }

    // MARK: - Tests

    func testALargeAttachmentStaysAtTheProviderUntilOpenedThenIsFetchedOnceAndTheOriginalIsExactWhenComplete() async throws {
        let sample = sample("Harbour project", seed: 1)
        try await append([sample.raw])
        try await sync()

        // Stored partially: text, search and classification work; the large parts wait.
        let id = try await onlyMessage()
        let partial = try await store.isPartial(id)
        XCTAssertTrue(partial)
        let stored = try await store.message(id)
        XCTAssertTrue(stored.isPartial)
        XCTAssertEqual(stored.textBody?.contains("quarterly figures for Harbour project"), true)
        XCTAssertNotNil(stored.htmlBody)
        let found = try await store.search("quarterly", account: account)
        XCTAssertEqual(found.map(\.id), [id], "search reads the text of a partial message")
        let verdict = try await store.verdict(of: id)
        XCTAssertNotNil(verdict, "classified on arrival like any message")
        var listed = try await attachments(id)
        XCTAssertEqual(Set(listed.keys), ["notes.txt", "photo.jpg", "figures.zip"])
        XCTAssertTrue(try XCTUnwrap(listed["notes.txt"]).isDownloaded, "small parts come with the text")
        let smallData = try await store.attachmentData(XCTUnwrap(listed["notes.txt"]))
        XCTAssertEqual(smallData, sample.small)
        XCTAssertFalse(try XCTUnwrap(listed["photo.jpg"]).isDownloaded)
        XCTAssertFalse(try XCTUnwrap(listed["figures.zip"]).isDownloaded)
        XCTAssertNotNil(listed["photo.jpg"]?.section)
        let downloaded = try await store.importedBytes(account: account)
        XCTAssertLessThan(downloaded, Int64(sample.raw.count / 2), "the large parts were not downloaded")

        // Never a complete original before it is one.
        do {
            _ = try await store.originalData(of: id)
            XCTFail("a partial message has no original")
        } catch MailStoreError.partialMessage {}
        do {
            _ = try await store.attachmentData(XCTUnwrap(listed["photo.jpg"]))
            XCTFail("not downloaded yet")
        } catch MailStoreError.attachmentNotDownloaded {}
        let report = try await store.integrityReport()
        XCTAssertEqual(report.failed, [])
        XCTAssertEqual(report.partial, [id], "listed as partial, not as checked")
        XCTAssertEqual(report.checked, 0)
        let exports = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let refused = try await store.export(.messages([id]), to: exports, name: "before")
        XCTAssertEqual(refused.partial, [id])
        XCTAssertEqual(refused.messages, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: refused.folder.appendingPathComponent("accounts").path),
                       "nothing of a partial message is exported")
        let mailFolderOriginals = try FileManager.default.subpathsOfDirectory(atPath: locations.mailFolder.path).filter { $0.hasSuffix(".eml") }
        XCTAssertEqual(mailFolderOriginals, [], "the mail folder holds originals only")
        let library = try await store.attachments()
        XCTAssertEqual(library.count, 3)
        XCTAssertEqual(library.filter { !$0.reference.isDownloaded }.map(\.reference.fileName).sorted(), ["figures.zip", "photo.jpg"])

        // Opening fetches it once: two opens at the same time share one download, a third reads the cache.
        let fetcher = fetcher()
        let before = sectionFetches()
        let photo = try XCTUnwrap(listed["photo.jpg"])
        async let first = fetcher.fetchAttachment(photo, of: id)
        async let second = fetcher.fetchAttachment(photo, of: id)
        let (one, two) = try await (first, second)
        XCTAssertEqual(one, two)
        XCTAssertTrue(one.isDownloaded)
        _ = try await fetcher.fetchAttachment(photo, of: id)
        XCTAssertEqual(sectionFetches() - before, 1, "fetched once")
        let photoData = try await store.attachmentData(one)
        XCTAssertEqual(photoData, sample.photo)
        let stillPartial = try await store.isPartial(id)
        XCTAssertTrue(stillPartial, "one part fetched, one still at the provider")

        // The last part completes the message: its original, byte for byte, in the mail folder.
        listed = try await attachments(id)
        let archive = try await fetcher.fetchAttachment(XCTUnwrap(listed["figures.zip"]), of: id)
        let archiveData = try await store.attachmentData(archive)
        XCTAssertEqual(archiveData, sample.archive)
        let complete = try await store.isPartial(id)
        XCTAssertFalse(complete)
        let original = try await store.originalData(of: id)
        XCTAssertEqual(original, sample.raw, "the original is exactly what the provider has")
        listed = try await attachments(id)
        XCTAssertEqual(listed["photo.jpg"]?.blob, one.blob, "the part fetched on demand is the same blob as in the original")
        XCTAssertTrue(listed.values.allSatisfy(\.isDownloaded))
        let checked = try await store.integrityReport()
        XCTAssertEqual(checked, IntegrityReport(failed: [], partial: [], checked: 1))
        let exported = try await store.export(.messages([id]), to: exports, name: "after")
        XCTAssertEqual(exported.messages, 1)
        XCTAssertEqual(exported.partial, [])
        let partialFiles = try FileManager.default.contentsOfDirectory(atPath: locations.deviceFolder.appendingPathComponent("partial/\(account.rawValue)").path)
        XCTAssertEqual(partialFiles, [], "the partial copy went once the original was in place")

        // Rebuilt from the folder, it is still one complete message with its id.
        try await store.rebuildIndex()
        let afterRebuild = try await store.summaries(account: account).map(\.id)
        XCTAssertEqual(afterRebuild, [id])
    }

    func testAPartialMessageSurvivesARebuildAndAReopenAndAMatchingCopyIsNotStoredTwice() async throws {
        let sample = sample("Survey results", seed: 10)
        try await append([sample.raw])
        try await append([sample.raw], to: "Archive")
        try await sync()
        let id = try await onlyMessage()
        let partial = try await store.isPartial(id)
        XCTAssertTrue(partial)
        let places = try await store.remoteLocations(of: id, account: account).map(\.mailbox).sorted()
        XCTAssertEqual(places, ["Archive", "INBOX"], "the copy in Archive is the same message")

        try await store.rebuildIndex()
        store = try await MailStore.open(locations)
        let again = try await onlyMessage()
        XCTAssertEqual(again, id)
        let stillPartial = try await store.isPartial(id)
        XCTAssertTrue(stillPartial)
        let found = try await store.search("survey", account: account)
        XCTAssertEqual(found.map(\.id), [id])
        // A second sync changes nothing.
        try await sync()
        let count = try await store.messageCount()
        XCTAssertEqual(count, 1)
    }

    func testOpeningAnAttachmentOfflineSaysSoAndWorksOnceOnline() async throws {
        let sample = sample("Offline trip", seed: 20)
        try await append([sample.raw])
        let proxy = try await FaultProxy(targetPort: server.imapsPort)
        let throughProxy = imap(port: proxy.port)
        try await sync(throughProxy)
        let id = try await onlyMessage()
        let listed = try await attachments(id)
        let photo = try XCTUnwrap(listed["photo.jpg"])
        await proxy.shutdown()

        do {
            _ = try await fetcher(throughProxy).fetchAttachment(photo, of: id)
            XCTFail("offline")
        } catch let failure as OnDemandFetcher.Failure {
            guard case .offline = failure else { return XCTFail("\(failure)") }
            XCTAssertTrue(failure.description.contains("offline"))
        }
        let stillPending = try await attachments(id)["photo.jpg"]
        XCTAssertEqual(stillPending?.isDownloaded, false, "nothing pretended to be downloaded")

        let fetched = try await fetcher().fetchAttachment(photo, of: id)
        let data = try await store.attachmentData(fetched)
        XCTAssertEqual(data, sample.photo)
    }

    func testAPinnedSpaceIsAllHereOfflineAndAPinnedConversationAndMessageToo() async throws {
        let a = sample("Pinned space one", seed: 30)
        let b = sample("Pinned space two", seed: 40)
        let c = sample("Pinned message", seed: 50)
        let d = sample("Not pinned", seed: 60)
        try await append([a.raw, b.raw, c.raw, d.raw])
        let proxy = try await FaultProxy(targetPort: server.imapsPort)
        let throughProxy = imap(port: proxy.port)
        try await sync(throughProxy)
        let ids = Dictionary(uniqueKeysWithValues: try await store.summaries(account: account).map { ($0.subject ?? "", $0.id) })
        let one = try XCTUnwrap(ids["Pinned space one"]), two = try XCTUnwrap(ids["Pinned space two"])
        let three = try XCTUnwrap(ids["Pinned message"]), four = try XCTUnwrap(ids["Not pinned"])

        let space = try await store.createSpace(name: "Trip")
        _ = try await store.addMessages([one, two], to: space.id)
        let covered = try await store.pin(.space(space.id))
        XCTAssertEqual(Set(covered), [one, two])
        try await store.pin(.message(three))
        let waiting = try await store.offlineStorage().pinnedWaiting
        XCTAssertEqual(waiting, 3)

        // The next pass downloads what the pins cover; then the connection goes.
        try await sync(throughProxy)
        await proxy.shutdown()
        for (id, sample) in [(one, a), (two, b), (three, c)] {
            let partial = try await store.isPartial(id)
            XCTAssertFalse(partial)
            let original = try await store.originalData(of: id)
            XCTAssertEqual(original, sample.raw)
            for attachment in try await store.message(id).front.attachments {
                let data = try await store.attachmentData(attachment)
                XCTAssertTrue([sample.small, sample.photo, sample.archive].contains(data))
            }
        }
        let unpinned = try await store.isPartial(four)
        XCTAssertTrue(unpinned, "what no pin covers stays partial")
        let after = try await store.offlineStorage()
        XCTAssertEqual(after.pinnedWaiting, 0)
        XCTAssertEqual(after.partialMessages, 1)

        // A pinned conversation, completed on request.
        let fourSummary = try await store.summaries(ids: [four])
        let thread = try XCTUnwrap(fourSummary.first?.threadID)
        let coveredThread = try await store.pin(.thread(thread))
        XCTAssertEqual(coveredThread, [four])
        let done = try await fetcher().downloadPinned()
        XCTAssertEqual(done, 1)
        let complete = try await store.isPartial(four)
        XCTAssertFalse(complete)
    }

    func testPartialMessagesInHistoryKeepToTheStorageBudgetAndNewMailDoesNot() async throws {
        try await append([sample("Oldest", seed: 90).raw, sample("Older", seed: 91).raw, sample("Newest", seed: 92).raw])
        // The newest is recent mail; the history budget is what that one stored: no room for more.
        let recentOnly = SyncOptions(recentPerFolder: 1, historyBudgetBytes: 1, onDemandThreshold: 64 * 1024)
        try await SyncCoordinator(account: account, connector: imap(), store: store, options: recentOnly, log: captured.log).syncOnce()
        let stored = try await store.summaries(account: account).compactMap(\.subject)
        XCTAssertEqual(stored, ["Newest"], "recent mail is stored even over the budget; partial history is held back")
        let partial = try await store.partialMessages(account: account).count
        XCTAssertEqual(partial, 1)

        try await append([sample("Arrived later", seed: 93).raw])
        try await SyncCoordinator(account: account, connector: imap(), store: store, options: recentOnly, log: captured.log).syncOnce()
        let after = Set(try await store.summaries(account: account).compactMap(\.subject))
        XCTAssertEqual(after, ["Newest", "Arrived later"], "new mail is never held back by the budget")
    }

    func testEvictionGivesBackOnlyUnpinnedPartsThatCanBeFetchedAgain() async throws {
        let a = sample("Keep this one", seed: 70)
        let b = sample("Let this one go", seed: 80)
        try await append([a.raw, b.raw])
        try await sync()
        let ids = Dictionary(uniqueKeysWithValues: try await store.summaries(account: account).map { ($0.subject ?? "", $0.id) })
        let kept = try XCTUnwrap(ids["Keep this one"]), loose = try XCTUnwrap(ids["Let this one go"])
        let fetcher = fetcher()
        let keptListed = try await attachments(kept)
        let looseListed = try await attachments(loose)
        let keptPhoto = try await fetcher.fetchAttachment(XCTUnwrap(keptListed["photo.jpg"]), of: kept)
        let loosePhoto = try await fetcher.fetchAttachment(XCTUnwrap(looseListed["photo.jpg"]), of: loose)
        try await store.pin(.message(kept))

        let before = try await store.offlineStorage()
        XCTAssertGreaterThan(before.cacheBytes, Int64(2 * 200 * 1024))
        XCTAssertEqual(before.evictableBytes, Int64(b.photo.count), "only the unpinned part fetched on demand")
        let result = try await store.evictCache(toFit: 0)
        XCTAssertEqual(result.removedParts, 1)
        XCTAssertEqual(result.removedBytes, Int64(b.photo.count))

        let keptData = try await store.attachmentData(keptPhoto)
        XCTAssertEqual(keptData, a.photo, "a pinned message keeps its parts")
        let small = try await store.attachmentData(XCTUnwrap(looseListed["notes.txt"]))
        XCTAssertEqual(small, b.small, "parts that came with the text stay")
        let evicted = try await attachments(loose)["photo.jpg"]
        XCTAssertEqual(evicted?.isDownloaded, false, "listed as not downloaded again")
        do {
            _ = try await store.attachmentData(loosePhoto)
            XCTFail("evicted")
        } catch {}
        let again = try await fetcher.fetchAttachment(XCTUnwrap(evicted), of: loose)
        let data = try await store.attachmentData(again)
        XCTAssertEqual(data, b.photo, "fetched again when opened")
    }
}
