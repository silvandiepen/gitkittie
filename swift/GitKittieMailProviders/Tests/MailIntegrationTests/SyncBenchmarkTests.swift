import Foundation
import MailCore
import MailIMAP
import MailProvider
import MailStore
import MailSync
import NIOConcurrencyHelpers
import NIOCore
import XCTest

/// How a large mailbox's first sync behaves (GKM-035, docs/Performance.md): a synthetic mailbox
/// of `GKM_SYNC_BENCHMARK_MESSAGES` messages (default 10,000) is appended to the real local
/// server, then synced by the real `SyncCoordinator` into a fresh `MailStore` on this disk,
/// three times: the first sync, a pass with nothing changed, and a pass after 100 new messages
/// and 500 flag changes. Opt-in, because it takes minutes and gigabytes:
///
///     GKM_SYNC_BENCHMARK=1 GKM_SYNC_BENCHMARK_MESSAGES=10000 \
///       swift test -c release --filter SyncBenchmarkTests
///
/// - `GKM_SYNC_BENCHMARK_ATTACHMENTS` scales the share of messages with attachments (default 1),
///   `GKM_SYNC_BENCHMARK_BODY_SCALE` the size of the text (default 1).
/// - `GKM_SYNC_BENCHMARK_FOLDER_SIZE` (default 1,000): the most messages per folder. GreenMail's
///   UID FETCH takes time proportional to the folder's size per message returned, so larger
///   folders measure GreenMail rather than the sync.
/// - `GKM_SYNC_BENCHMARK_RTT_MS` / `GKM_SYNC_BENCHMARK_MBPS` put the fault proxy between the
///   sync and the server with that round trip (and link speed), to estimate a distant provider.
/// - `GKM_SYNC_BENCHMARK_OUT` writes the results as JSON to that path.
///
/// Everything it creates (the test account and its mail on the server, the store) is deleted
/// at the end, also when it fails.
final class SyncBenchmarkTests: XCTestCase {
    private static let account = MailAccountID("bench")

    func testFirstSyncOfALargeMailbox() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GKM_SYNC_BENCHMARK"] == "1" else {
            throw XCTSkip("The sync benchmark is opt-in: GKM_SYNC_BENCHMARK=1 (docs/Performance.md).")
        }
        let count = Int(environment["GKM_SYNC_BENCHMARK_MESSAGES"] ?? "") ?? 10_000
        let attachmentShare = Double(environment["GKM_SYNC_BENCHMARK_ATTACHMENTS"] ?? "") ?? 1
        let bodyScale = Double(environment["GKM_SYNC_BENCHMARK_BODY_SCALE"] ?? "") ?? 1
        let folderSize = Int(environment["GKM_SYNC_BENCHMARK_FOLDER_SIZE"] ?? "") ?? 1_000
        let roundTrip = Int(environment["GKM_SYNC_BENCHMARK_RTT_MS"] ?? "") ?? 0
        let megabits = Int(environment["GKM_SYNC_BENCHMARK_MBPS"] ?? "")

        let server = try await TestMailServer.require()
        let user = try await server.makeUser(function: "bench")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gkm-bench-\(UUID().uuidString)", isDirectory: true)
        var proxy: FaultProxy?
        do {
            let mailbox = SyntheticMailbox(count: count, owner: user.address, attachmentShare: attachmentShare, bodyScale: bodyScale,
                                           folderSize: folderSize)
            // The store keeps the original, its Markdown, decoded attachments and the index:
            // a little over twice the mail. Refuse rather than fill a shared disk: by default 3 GB stay
            // free (GKM_SYNC_BENCHMARK_KEEP_FREE_GB).
            let keepFree = Int64((Double(environment["GKM_SYNC_BENCHMARK_KEEP_FREE_GB"] ?? "") ?? 3) * 1e9)
            let needed = mailbox.approximateBytes * 5 / 2 + keepFree
            let free = ProcessMetrics.freeSpace(at: FileManager.default.temporaryDirectory)
            guard free > needed else {
                XCTFail("Not enough free disk: \(Self.mb(free)) free, about \(Self.mb(needed)) needed for \(count) messages. Lower GKM_SYNC_BENCHMARK_ATTACHMENTS or the count.")
                try await Self.deleteUser(user, server: server)
                return
            }
            Self.report("benchmark: \(count) messages in \(mailbox.folders.count) folders, about \(Self.mb(mailbox.approximateBytes)) of mail; \(Self.mb(free)) free disk")

            let seedClock = ContinuousClock.now
            try await Self.seed(mailbox, server: server, user: user)
            Self.report("seeded in \(Self.format(ContinuousClock.now - seedClock))")

            var port = server.imapsPort
            if roundTrip > 0 {
                let link = LinkConditions(roundTrip: .milliseconds(Int64(roundTrip)), bitsPerSecond: megabits.map { $0 * 1_000_000 })
                proxy = try await FaultProxy(targetPort: server.imapsPort, mode: .slowLink(link))
                port = proxy!.port
                Self.report("through a simulated link: \(roundTrip) ms round trip" + (megabits.map { ", \($0) Mbit/s" } ?? ""))
            }

            let locations = StoreLocations(mailFolder: root.appendingPathComponent("Mail"), deviceFolder: root.appendingPathComponent("Support/Mail"))
            let store = try await MailStore.open(locations)
            let commands = NIOLockedValueBox(0)
            let log = MailLog(minimumLevel: .debug) { record in
                if record.category == "imap", record.message.hasPrefix("→") { commands.withLockedValue { $0 += 1 } }
            }
            let connector = IMAPConnector(
                endpoint: ServerEndpoint(host: "localhost", port: port, security: .implicitTLS, trust: server.trust),
                credential: user.credential, log: log, commandTimeout: .seconds(120))
            let serverPID = (try? String(contentsOf: server.stateDirectory.appendingPathComponent("greenmail.pid"), encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

            func pass(_ name: String) async throws -> PassResult {
                let coordinator = SyncCoordinator(account: Self.account, connector: connector, store: store, log: log)
                return try await Self.measure(name, coordinator: coordinator, commands: commands, serverPID: serverPID,
                                              minimumFree: keepFree / 2)
            }

            var results: [PassResult] = []
            var first = try await pass("first sync")
            let stored = try await store.messageCount()
            XCTAssertEqual(stored, count, "every message is stored once")
            first.mailFolderBytes = ProcessMetrics.diskUsage(of: locations.mailFolder)
            first.deviceFolderBytes = ProcessMetrics.diskUsage(of: locations.deviceFolder)
            first.indexBytes = ["", "-wal", "-shm"].reduce(0) { total, suffix in
                total + ProcessMetrics.fileSize(locations.deviceFolder.appendingPathComponent("index.sqlite" + suffix))
            }
            results.append(first)
            Self.report(first.summary)

            let unchanged = try await pass("nothing changed")
            XCTAssertEqual(unchanged.imported, 0)
            results.append(unchanged)
            Self.report(unchanged.summary)

            let expected = try await Self.change(mailbox, server: server, user: user, store: store)
            let changed = try await pass("100 new, 500 flag changes")
            results.append(changed)
            Self.report(changed.summary)
            let storedAfter = try await store.messageCount()
            XCTAssertEqual(storedAfter, count + 100)
            var mismatches = 0
            for (location, flags) in expected {
                guard let id = try await store.localID(at: location, account: Self.account) else { mismatches += 1; continue }
                let local = try await store.flags(of: [id], account: Self.account)[id]
                if local?.seen != flags.seen || local?.flagged != flags.flagged { mismatches += 1 }
            }
            XCTAssertEqual(mismatches, 0, "every flag change reached the store")

            if let path = environment["GKM_SYNC_BENCHMARK_OUT"] {
                let document: [String: Any] = [
                    "messages": count, "attachmentShare": attachmentShare, "bodyScale": bodyScale, "folderSize": folderSize, "folders": mailbox.folders.count, "roundTripMs": roundTrip, "megabits": megabits ?? 0,
                    "approximateMailBytes": mailbox.approximateBytes, "passes": results.map(\.json),
                ]
                try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: path))
            }
        } catch {
            await proxy?.shutdown()
            try? FileManager.default.removeItem(at: root)
            try? await Self.deleteUser(user, server: server)
            throw error
        }
        await proxy?.shutdown()
        try? FileManager.default.removeItem(at: root)
        try await Self.deleteUser(user, server: server)
    }

    // MARK: - Measuring

    struct PassResult {
        var name: String
        var seconds = 0.0
        var firstVisibleSeconds: Double?
        var imported = 0
        /// Seconds to reach each tenth of the messages imported.
        var deciles: [Double] = []
        var peakFootprint: Int64 = 0
        var cpuSeconds = 0.0
        var serverCPUSeconds: Double?
        var diskBytesWritten: Int64 = 0
        var io = StoreIOStatistics.Snapshot()
        var imapCommands = 0
        var mailFolderBytes: Int64 = 0
        var deviceFolderBytes: Int64 = 0
        var indexBytes: Int64 = 0

        var messagesPerSecond: Double { seconds > 0 ? Double(imported) / seconds : 0 }

        /// Messages per second within each tenth of the import.
        var decileRates: [Double] {
            guard imported >= 10, deciles.count == 10 else { return [] }
            return deciles.indices.map { index in
                let start = index == 0 ? 0 : deciles[index - 1]
                let span = deciles[index] - start
                return span > 0 ? Double(imported) / 10 / span : 0
            }
        }

        var summary: String {
            var lines = ["── \(name): \(String(format: "%.1f", seconds)) s, \(imported) imported (\(String(format: "%.0f", messagesPerSecond))/s)"]
            if let firstVisibleSeconds { lines.append("   first 200 visible after \(String(format: "%.2f", firstVisibleSeconds)) s") }
            if !decileRates.isEmpty { lines.append("   msgs/s by tenth: " + decileRates.map { String(format: "%.0f", $0) }.joined(separator: " ")) }
            lines.append("   peak footprint \(SyncBenchmarkTests.mb(peakFootprint)), CPU \(String(format: "%.1f", cpuSeconds)) s"
                         + (serverCPUSeconds.map { String(format: " (server %.1f s)", $0) } ?? ""))
            lines.append("   disk written \(SyncBenchmarkTests.mb(diskBytesWritten)); store: \(io.filesWritten) files, \(io.fileSyncs) file fsyncs, "
                         + "\(io.directorySyncs) directory fsyncs, \(io.indexCommits) index commits, \(io.syncStateCommits) sync-state commits")
            lines.append("   IMAP commands \(imapCommands)")
            if mailFolderBytes > 0 {
                lines.append("   mail folder \(SyncBenchmarkTests.mb(mailFolderBytes)), device folder \(SyncBenchmarkTests.mb(deviceFolderBytes)) (index \(SyncBenchmarkTests.mb(indexBytes)))")
            }
            return lines.joined(separator: "\n")
        }

        var json: [String: Any] {
            [
                "name": name, "seconds": seconds, "firstVisibleSeconds": firstVisibleSeconds ?? -1, "imported": imported,
                "messagesPerSecond": messagesPerSecond, "decileRates": decileRates, "peakFootprintBytes": peakFootprint,
                "cpuSeconds": cpuSeconds, "serverCPUSeconds": serverCPUSeconds ?? -1, "diskBytesWritten": diskBytesWritten,
                "filesWritten": io.filesWritten, "fileSyncs": io.fileSyncs, "directorySyncs": io.directorySyncs,
                "indexCommits": io.indexCommits, "syncStateCommits": io.syncStateCommits, "imapCommands": imapCommands,
                "mailFolderBytes": mailFolderBytes, "deviceFolderBytes": deviceFolderBytes, "indexBytes": indexBytes,
            ]
        }
    }

    private static func measure(_ name: String, coordinator: SyncCoordinator, commands: NIOLockedValueBox<Int>,
                         serverPID: pid_t?, minimumFree: Int64) async throws -> PassResult {
        var result = PassResult(name: name)
        let io = StoreIOStatistics.snapshot()
        let usage = ProcessMetrics.usage()
        let serverUsage = serverPID.flatMap { ProcessMetrics.usage(of: $0) }
        let commandsBefore = commands.withLockedValue { $0 }
        let clock = ContinuousClock()
        let start = clock.now

        // The first moment 200 messages are in the store (and so in the list).
        let firstVisible = Task { () -> Duration? in
            for await progress in coordinator.updates where progress.imported >= 200 { return clock.now - start }
            return nil
        }
        let sync = Task { try await coordinator.syncOnce() }
        // Memory and progress, four times a second; the disk is shared, so stop the sync before
        // it runs out (the volume can fill from elsewhere while this runs).
        let sampler = Task { () -> (peak: Int64, samples: [(Duration, Int)], stoppedForDisk: Bool) in
            var peak: Int64 = 0
            var samples: [(Duration, Int)] = []
            while !Task.isCancelled {
                peak = max(peak, ProcessMetrics.footprint())
                samples.append((clock.now - start, await coordinator.progress.imported))
                if ProcessMetrics.freeSpace(at: FileManager.default.temporaryDirectory) < minimumFree {
                    sync.cancel()
                    return (peak, samples, true)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return (peak, samples, false)
        }

        let outcome = await sync.result
        let elapsed = clock.now - start
        sampler.cancel()
        let sampled = await sampler.value
        if sampled.stoppedForDisk { throw DiskTooFull(minimumFree: minimumFree) }
        try outcome.get()
        result.seconds = Self.seconds(elapsed)
        firstVisible.cancel()
        let (peak, samples, _) = sampled
        result.peakFootprint = max(peak, ProcessMetrics.footprint())
        result.imported = await coordinator.progress.imported
        if result.imported >= 200, let visible = await firstVisible.value { result.firstVisibleSeconds = Self.seconds(visible) }
        if result.imported >= 10 {
            let all = samples + [(clock.now - start, result.imported)]
            result.deciles = (1...10).map { tenth in
                let wanted = result.imported * tenth / 10
                return Self.seconds(all.first { $0.1 >= wanted }?.0 ?? (clock.now - start))
            }
        }
        if let before = usage, let after = ProcessMetrics.usage() {
            result.cpuSeconds = (after - before).cpuSeconds
            result.diskBytesWritten = (after - before).diskBytesWritten
        }
        if let pid = serverPID, let before = serverUsage, let after = ProcessMetrics.usage(of: pid) {
            result.serverCPUSeconds = (after - before).cpuSeconds
        }
        result.io = StoreIOStatistics.snapshot() - io
        result.imapCommands = commands.withLockedValue { $0 } - commandsBefore
        return result
    }

    struct DiskTooFull: Error, CustomStringConvertible {
        var minimumFree: Int64
        var description: String { "stopped: less than \(SyncBenchmarkTests.mb(minimumFree)) free on the disk" }
    }

    // MARK: - The mailbox at the server

    private static func seeder(_ server: TestMailServer, _ user: TestUser) -> IMAPConnector {
        IMAPConnector(endpoint: server.imaps, credential: user.credential, commandTimeout: .seconds(120))
    }

    private static func seed(_ mailbox: SyntheticMailbox, server: TestMailServer, user: TestUser) async throws {
        try await Self.seeder(server, user).withSession { session in
            let existing = Set(try await session.listFolders().map(\.id))
            for folder in mailbox.folders where !existing.contains(folder) { try await session.createFolder(folder) }
            for spec in mailbox.specs {
                _ = try await session.append(mailbox.message(spec), to: spec.folder, flags: spec.flags)
                if (spec.index + 1) % 5_000 == 0 { Self.report("  seeded \(spec.index + 1)") }
            }
        }
    }

    /// 100 new messages in the inbox and 500 flag changes on stored ones (250 flagged, 250
    /// marked unread); returns the flags each changed message must end up with locally.
    private static func change(_ mailbox: SyntheticMailbox, server: TestMailServer, user: TestUser,
                        store: MailStore) async throws -> [(RemoteLocation, MailMessageFlags)] {
        try await Self.seeder(server, user).withSession { session in
            let listing = try await session.listing(of: "INBOX")
            var random = SplitMix64(seed: 7)
            var chosen = Set<UInt32>()
            while chosen.count < min(500, listing.uids.count) { chosen.insert(listing.uids[random.int(in: 0...(listing.uids.count - 1))]) }
            let ordered = chosen.sorted()
            let flagIDs = ordered.prefix(250).map { RemoteMessageID(folder: "INBOX", uidValidity: listing.status.uidValidity, uid: $0) }
            let unreadIDs = ordered.dropFirst(250).map { RemoteMessageID(folder: "INBOX", uidValidity: listing.status.uidValidity, uid: $0) }
            try await session.setFlags(MessageFlags(flagged: true), .add, on: flagIDs)
            try await session.setFlags(MessageFlags(seen: true), .remove, on: unreadIDs)
            let after = try await session.flags(of: flagIDs + unreadIDs)
            var expected: [(RemoteLocation, MailMessageFlags)] = []
            for (id, flags) in after {
                expected.append((RemoteLocation(mailbox: id.folder, uidValidity: id.uidValidity, uid: id.uid),
                                 MailMessageFlags(seen: flags.seen, answered: flags.answered, flagged: flags.flagged, draft: flags.draft)))
            }
            let newest = mailbox.specs.last!.date
            for index in 0..<100 {
                var spec = mailbox.specs[mailbox.specs.count - 1 - index]
                spec.folder = "INBOX"
                spec.date = newest.addingTimeInterval(Double(index + 1) * 600)
                _ = try await session.append(mailbox.message(spec, variant: "new"), to: "INBOX", flags: MessageFlags())
            }
            return expected
        }
    }

    /// Deletes the benchmark's account and its mail from the server. GreenMail sometimes answers
    /// 500 after deleting, so the user list is the proof.
    private static func deleteUser(_ user: TestUser, server: TestMailServer) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.apiPort)/api/user/\(user.address)")!)
        request.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: request)
        let (list, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(server.apiPort)/api/user")!)
        if String(decoding: list, as: UTF8.self).contains(user.address) { Self.report("warning: the test user \(user.address) is still on the server") }
    }

    // MARK: - Formatting

    private static func report(_ line: String) { print("[GKM-BENCH] " + line.replacingOccurrences(of: "\n", with: "\n[GKM-BENCH] ")) }

    static func mb(_ bytes: Int64) -> String { String(format: "%.0f MB", Double(bytes) / 1_000_000) }
    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    static func format(_ duration: Duration) -> String { String(format: "%.1f s", seconds(duration)) }
}
