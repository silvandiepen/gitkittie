import XCTest
import os
import MailCore
import MailTestSupport
@testable import MailStore

/// The sync's batched write (GKM-035): the same rules as storing messages one by one, and the
/// same all-or-nothing guarantee per message when a write stops anywhere in the batch.
final class SyncBatchTests: XCTestCase {
    private var root: URL!
    private var locations: StoreLocations!
    private let account = MailAccountID("acct-batch")
    private let received = Date(timeIntervalSince1970: 1_795_600_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("syncbatch-\(UUID().uuidString)", isDirectory: true)
        locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func location(_ uid: UInt32, in mailbox: String = "INBOX") -> RemoteLocation {
        RemoteLocation(mailbox: mailbox, uidValidity: 1, uid: uid)
    }

    private func batch(_ corpus: [Data], from uid: UInt32 = 1, in mailbox: String = "INBOX",
                       flags: MailMessageFlags = MailMessageFlags(seen: true)) -> [SyncedMessage] {
        corpus.enumerated().map { SyncedMessage(eml: $1, remote: location(uid + UInt32($0), in: mailbox), receivedAt: received, flags: flags) }
    }

    func testABatchStoresEachMessageOnceWithItsFlagsAndMatchesCopiesInsteadOfDuplicating() async throws {
        let store = try await MailStore.open(locations)
        let corpus = SyntheticMail.corpus
        // The last one is the first again, at another UID in the same batch (a copy).
        var messages = batch(corpus)
        messages.append(SyncedMessage(eml: corpus[0], remote: location(99), receivedAt: received, flags: MailMessageFlags()))
        let outcomes = try await store.storeSynced(messages, account: account)

        XCTAssertEqual(outcomes.count, corpus.count + 1)
        XCTAssertTrue(outcomes.dropLast().allSatisfy { if case .stored = $0 { return true }; return false }, "\(outcomes)")
        XCTAssertEqual(outcomes.last, .matched(outcomes[0].id), "the copy is the same message")
        let count = try await store.messageCount()
        XCTAssertEqual(count, corpus.count)
        for (offset, outcome) in outcomes.dropLast().enumerated() {
            let original = try await store.originalData(of: outcome.id)
            XCTAssertEqual(original, corpus[offset])
            let mapped = try await store.localID(at: location(UInt32(offset + 1)), account: account)
            XCTAssertEqual(mapped, outcome.id)
        }
        let copyLocations = try await store.remoteLocations(of: outcomes[0].id, account: account)
        XCTAssertEqual(Set(copyLocations), [location(1), location(99)])
        let flags = try await store.flags(of: [outcomes[1].id], account: account)
        XCTAssertEqual(flags[outcomes[1].id], MailMessageFlags(seen: true))
        let unread = try await store.unreadCount(account: account)
        XCTAssertEqual(unread, 0, "the list shows the synced flags")
        let bytes = try await store.importedBytes(account: account)
        XCTAssertEqual(bytes, Int64(corpus.reduce(0) { $0 + $1.count }), "each original counts once")
        let inbox = try await store.summaries(account: account, mailbox: "INBOX")
        XCTAssertEqual(inbox.count, corpus.count)

        // The same batch again (a crash before the cursor was saved): nothing new.
        let again = try await store.storeSynced(batch(corpus, flags: MailMessageFlags(seen: false, flagged: true)), account: account)
        XCTAssertEqual(again, outcomes.dropLast().map { .alreadyStored($0.id) })
        let after = try await store.messageCount()
        XCTAssertEqual(after, corpus.count)
        let changed = try await store.flags(of: [outcomes[1].id], account: account)
        XCTAssertEqual(changed[outcomes[1].id], MailMessageFlags(flagged: true), "flags follow the provider")

        // Stored before, now seen in another folder: a second location, not a copy.
        let moved = try await store.storeSynced([SyncedMessage(eml: corpus[2], remote: location(5, in: "Archive"), receivedAt: received,
                                                               flags: MailMessageFlags())], account: account)
        XCTAssertEqual(moved, [.matched(outcomes[2].id)])
        let archive = try await store.summaries(account: account, mailbox: "Archive").map(\.id)
        XCTAssertEqual(archive, [outcomes[2].id])
    }

    /// Kill the batch write at every step, including halfway through its messages: each
    /// message is then wholly there (its `.eml` was renamed into place; recovery completes the
    /// index and the mapping) or wholly absent, nothing temporary is left, and what was stored
    /// before is untouched.
    func testAKilledBatchWriteLeavesEachMessageWhollyThereOrWhollyAbsent() async throws {
        let corpus = SyntheticMail.corpus
        let first = Array(corpus.prefix(2))
        let interrupted = Array(corpus.dropFirst(2))
        XCTAssertGreaterThanOrEqual(interrupted.count, 3)
        // (name, the step to stop at, how many of the interrupted batch survive)
        let steps: [(String, @Sendable (WriteStep) -> Bool, Int)] = [
            ("journal", { if case .beforeRename(let name) = $0 { return name.hasSuffix(".json") }; return false }, 0),
            ("blob", { if case .beforeRename(let name) = $0 { return name.count == 64 }; return false }, 0),
            ("first markdown", { if case .beforeRename(let name) = $0 { return name.hasSuffix(".md") }; return false }, 0),
            ("first original", { if case .beforeRename(let name) = $0 { return name.hasSuffix(".eml") }; return false }, 0),
            ("index", { $0 == .beforeIndex }, interrupted.count),
        ]
        for (name, matches, survivors) in steps {
            try? FileManager.default.removeItem(at: root)
            do {
                let store = try await MailStore.open(locations)
                _ = try await store.storeSynced(batch(first), account: account)
            }
            do {
                let crashing = try await MailStore.open(locations, faults: WriteFaults { if matches($0) { throw Kill() } })
                await XCTAssertThrowsErrorAsync(try await crashing.storeSynced(batch(interrupted, from: 10), account: account), name)
            }
            try await assertRecovered(name, kept: first.count, survivors: survivors, of: interrupted, from: 10)
        }

        // Halfway: the second message's original never made it, the first's did.
        try? FileManager.default.removeItem(at: root)
        do {
            let store = try await MailStore.open(locations)
            _ = try await store.storeSynced(batch(first), account: account)
        }
        let renamed = OSAllocatedUnfairLock(initialState: 0)
        do {
            let crashing = try await MailStore.open(locations, faults: WriteFaults { step in
                guard case .beforeRename(let file) = step, file.hasSuffix(".eml") else { return }
                if renamed.withLock({ $0 += 1; return $0 }) == 2 { throw Kill() }
            })
            await XCTAssertThrowsErrorAsync(try await crashing.storeSynced(batch(interrupted, from: 10), account: account), "halfway")
        }
        try await assertRecovered("halfway", kept: first.count, survivors: 1, of: interrupted, from: 10)
    }

    private func assertRecovered(_ name: String, kept: Int, survivors: Int, of interrupted: [Data], from uid: UInt32) async throws {
        let store = try await MailStore.open(locations)
        let count = try await store.messageCount()
        XCTAssertEqual(count, kept + survivors, name)
        for (offset, eml) in interrupted.enumerated() {
            let mapped = try await store.localID(at: location(uid + UInt32(offset)), account: account)
            XCTAssertEqual(mapped != nil, offset < survivors, "\(name): message \(offset)")
            if let mapped {
                let original = try await store.originalData(of: mapped)
                XCTAssertEqual(original, eml, "\(name): message \(offset)")
                let inbox = try await store.summaries(account: account, mailbox: "INBOX").contains { $0.id == mapped }
                XCTAssertTrue(inbox, "\(name): the recovered message is in its folder")
            }
        }
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter {
            $0.hasSuffix(AtomicWriter.partialSuffix) || $0.contains("state/journal/") && $0.hasSuffix(".json")
        }
        XCTAssertEqual(leftovers, [], name)
        let all = try FileManager.default.subpathsOfDirectory(atPath: locations.mailFolder.path)
        let originals = Set(all.filter { $0.hasSuffix(".eml") }.map { ($0 as NSString).deletingPathExtension })
        let markdown = Set(all.filter { $0.hasSuffix(".md") }.map { ($0 as NSString).deletingPathExtension })
        XCTAssertEqual(originals, markdown, "\(name): every .eml has its .md and no .md is alone")
        let failed = try await store.verifyIntegrity()
        XCTAssertEqual(failed, [], name)
    }

    private struct Kill: Error {}

}
