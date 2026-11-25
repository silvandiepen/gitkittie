import Foundation
import MailCore
import MailStore
import XCTest

/// The client's half of a first sync, without a server (GKM-040, docs/Performance.md): the
/// benchmark's synthetic mailbox stored straight into a fresh `MailStore` with `storeSynced`, in
/// fetch-sized batches of 100, as the sync stores them, classification included. It measures
/// what grows with the mailbox in the store alone, without the test server's own cost or noise.
/// Opt-in:
///
///     GKM_STORE_BENCHMARK=1 GKM_STORE_BENCHMARK_MESSAGES=50000 \
///       swift test -c release -Xswiftc -enable-testing --filter StoreBenchmarkTests
///
/// `GKM_SYNC_BENCHMARK_BODY_SCALE` and `GKM_SYNC_BENCHMARK_ATTACHMENTS` shape the mailbox as in
/// `SyncBenchmarkTests`. The store is deleted at the end.
final class StoreBenchmarkTests: XCTestCase {
    func testStoringALargeMailbox() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GKM_STORE_BENCHMARK"] == "1" else {
            throw XCTSkip("The store benchmark is opt-in: GKM_STORE_BENCHMARK=1 (docs/Performance.md).")
        }
        let count = Int(environment["GKM_STORE_BENCHMARK_MESSAGES"] ?? "") ?? 10_000
        let attachmentShare = Double(environment["GKM_SYNC_BENCHMARK_ATTACHMENTS"] ?? "") ?? 1
        let bodyScale = Double(environment["GKM_SYNC_BENCHMARK_BODY_SCALE"] ?? "") ?? 1
        let account = MailAccountID("bench")
        let mailbox = SyntheticMailbox(count: count, owner: "owner@example.com", attachmentShare: attachmentShare,
                                       bodyScale: bodyScale, folderSize: 1_000)
        let free = ProcessMetrics.freeSpace(at: FileManager.default.temporaryDirectory)
        guard free > mailbox.approximateBytes * 5 / 2 + 3_000_000_000 else {
            XCTFail("Not enough free disk: \(SyncBenchmarkTests.mb(free)) free for \(count) messages.")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm-store-bench-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await MailStore.open(StoreLocations(mailFolder: root.appendingPathComponent("Mail"),
                                                            deviceFolder: root.appendingPathComponent("Support/Mail")))
        print("[GKM-STORE-BENCH] \(count) messages, about \(SyncBenchmarkTests.mb(mailbox.approximateBytes))")

        let clock = ContinuousClock()
        let start = clock.now
        let cpuStart = (ProcessMetrics.usage()?.cpuSeconds ?? 0)
        var tenthStart = start
        var tenthCPU = cpuStart
        var rates: [Double] = []
        var cpuPerMessage: [Double] = []
        var uids: [String: UInt32] = [:]
        // Oldest first, as the server holds them; the sync fetches the newest first, which
        // changes nothing the store does per message.
        var stored = 0
        for chunk in stride(from: 0, to: count, by: 100) {
            let batch = mailbox.specs[chunk..<min(count, chunk + 100)].map { spec -> SyncedMessage in
                let uid = (uids[spec.folder] ?? 0) + 1
                uids[spec.folder] = uid
                return SyncedMessage(eml: mailbox.message(spec), remote: RemoteLocation(mailbox: spec.folder, uidValidity: 1, uid: uid),
                                     receivedAt: spec.date, flags: MailMessageFlags(seen: spec.flags.seen, answered: spec.flags.answered,
                                                                                    flagged: spec.flags.flagged))
            }
            _ = try await store.storeSynced(batch, account: account)
            let before = stored
            stored += batch.count
            if stored * 10 / count > before * 10 / count {
                let now = clock.now, cpu = (ProcessMetrics.usage()?.cpuSeconds ?? 0)
                let tenth = count / 10
                rates.append(Double(tenth) / SyncBenchmarkTests.seconds(now - tenthStart))
                cpuPerMessage.append((cpu - tenthCPU) * 1_000 / Double(tenth))
                tenthStart = now
                tenthCPU = cpu
            }
        }
        let total = SyncBenchmarkTests.seconds(clock.now - start)
        let messages = try await store.messageCount()
        XCTAssertEqual(messages, count, "every message is stored once")
        let pending = try await store.pendingClassificationCount()
        XCTAssertEqual(pending, 0, "every message is classified as it is stored")
        print(String(format: "[GKM-STORE-BENCH] stored in %.1f s (%.0f/s), CPU %.1f s", total, Double(count) / total,
                     (ProcessMetrics.usage()?.cpuSeconds ?? 0) - cpuStart))
        print("[GKM-STORE-BENCH] msgs/s by tenth: " + rates.map { String(format: "%.0f", $0) }.joined(separator: " "))
        print("[GKM-STORE-BENCH] CPU ms/message by tenth: " + cpuPerMessage.map { String(format: "%.2f", $0) }.joined(separator: " "))
        let failure = await store.lastClassificationError
        XCTAssertNil(failure, "classification failed")
    }
}
