import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// A source that can be switched to "no connection" or "refuses writes", and counts what
/// actually reached it.
private actor SwitchableSource: BoardWritable {
    enum Mode { case online, offline, refusing }
    private let inner = InMemoryBoardSource(files: ["Board/1. To do/existing.md": "---\nid: existing\n---\n"])
    private var mode: Mode = .online
    private(set) var writes: [String] = []

    func set(_ mode: Mode) { self.mode = mode }

    private func check() throws {
        switch mode {
        case .online: return
        case .offline: throw URLError(.notConnectedToInternet)
        case .refusing: throw BoardSourceError(message: "Refused by the server.")
        }
    }

    func list(_ directory: String) async throws -> [BoardFileEntry] { try check(); return await inner.list(directory) }
    func readText(_ path: String) async throws -> String { try check(); return try await inner.readText(path) }
    func readData(_ path: String) async throws -> Data { try check(); return try await inner.readData(path) }
    func write(path: String, text: String, message: String) async throws {
        try check(); writes.append(path); await inner.write(path: path, text: text, message: message)
    }
    func writeData(path: String, data: Data, message: String) async throws {
        try check(); writes.append(path)
        if let text = String(data: data, encoding: .utf8) { await inner.write(path: path, text: text, message: message) }
        else { await inner.writeData(path: path, data: data, message: message) }
    }
    func delete(path: String, message: String) async throws { try check(); writes.append("-" + path); await inner.delete(path: path, message: message) }
}

final class OutboxTests: XCTestCase {
    private var directory: URL!
    private var remote: SwitchableSource!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("gk-outbox-\(UUID().uuidString)", isDirectory: true)
        remote = SwitchableSource()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private func outbox() -> Outbox { Outbox(directory: directory.appendingPathComponent("Outbox")) }

    private func source(_ outbox: Outbox) -> OutboxSource {
        OutboxSource(base: remote, outbox: outbox, repoKey: "repo",
                     cache: ReadCache(directory: directory.appendingPathComponent("Cache")), saved: {})
    }

    private func flush(_ outbox: Outbox) async -> Int {
        let remote = remote!
        return await outbox.flush(resolve: { _ in remote }, changed: {})
    }

    func testAWriteIsVisibleAtOnceAndSentLater() async throws {
        let outbox = outbox()
        let source = source(outbox)
        try await source.write(path: "Board/1. To do/new.md", text: "hello", message: "Add task new")
        try await source.writeData(path: "Board/attachments/new/shot.png", data: Data([1, 2, 3]), message: "Attach shot.png")

        // Nothing has reached the server, but reads already include it.
        let sentSoFar = await remote.writes
        XCTAssertEqual(sentSoFar, [])
        let names = try await source.list("Board/1. To do").map(\.name).sorted()
        XCTAssertEqual(names, ["existing.md", "new.md"])
        let text = try await source.readText("Board/1. To do/new.md")
        XCTAssertEqual(text, "hello")
        let folders = try await source.list("Board").map(\.name).sorted()
        XCTAssertEqual(folders, ["1. To do", "attachments"], "a folder that only exists in the outbox is listed")
        let attachments = try await source.list("Board/attachments/new").map(\.name)
        XCTAssertEqual(attachments, ["shot.png"])

        let sent = await flush(outbox)
        XCTAssertEqual(sent, 2)
        let writes = await remote.writes
        XCTAssertEqual(writes, ["Board/1. To do/new.md", "Board/attachments/new/shot.png"], "sent in the order they were made")
        let left = await outbox.operations()
        XCTAssertTrue(left.isEmpty)
        let receipts = await outbox.receipts()
        XCTAssertEqual(receipts.map(\.message), ["Attach shot.png", "Add task new"])
    }

    func testOfflineKeepsEverythingWaitingAndTheBoardReadable() async throws {
        let outbox = outbox()
        let source = source(outbox)
        _ = try await source.list("Board/1. To do")            // read once while online
        _ = try await source.readText("Board/1. To do/existing.md")

        await remote.set(.offline)
        try await source.write(path: "Board/1. To do/offline.md", text: "made offline", message: "Add task offline")
        let names = try await source.list("Board/1. To do").map(\.name).sorted()
        XCTAssertEqual(names, ["existing.md", "offline.md"], "the last listing plus what was made offline")
        let cached = try await source.readText("Board/1. To do/existing.md")
        XCTAssertTrue(cached.contains("id: existing"))

        let sentOffline = await flush(outbox)
        XCTAssertEqual(sentOffline, 0)
        let waiting = await outbox.operations()
        XCTAssertEqual(waiting.map(\.state), [.pending])
        XCTAssertEqual(waiting.first?.note, "Waiting for a connection.")

        // A relaunch (a new Outbox over the same folder) still has it, and sends it once online.
        await remote.set(.online)
        let relaunched = self.outbox()
        let sent = await flush(relaunched)
        XCTAssertEqual(sent, 1)
        let writes = await remote.writes
        XCTAssertEqual(writes, ["Board/1. To do/offline.md"])
    }

    func testARefusedWriteFailsHoldsBackItsFileAndCanBeRetriedOrDiscarded() async throws {
        let outbox = outbox()
        let source = source(outbox)
        await remote.set(.refusing)
        try await source.write(path: "Board/1. To do/a.md", text: "one", message: "Add task a")
        try await source.write(path: "Board/1. To do/a.md", text: "two", message: "Update a")
        try await source.write(path: "Board/1. To do/b.md", text: "bee", message: "Add task b")
        _ = await flush(outbox)
        var states = await outbox.operations().map(\.state)
        XCTAssertEqual(states, [.failed, .pending, .failed], "the second write to a.md waits behind the refused one")

        await remote.set(.online)
        let untouched = await flush(outbox)
        XCTAssertEqual(untouched, 0, "a refused write is not retried by itself")

        let failed = await outbox.operations()
        await outbox.retry(failed[0].id)
        await outbox.discard(failed[2].id)
        let sent = await flush(outbox)
        XCTAssertEqual(sent, 2)
        states = await outbox.operations().map(\.state)
        XCTAssertEqual(states, [])
        let writes = await remote.writes
        XCTAssertEqual(writes, ["Board/1. To do/a.md", "Board/1. To do/a.md"])
        let final = try await source.readText("Board/1. To do/a.md")
        XCTAssertEqual(final, "two")
    }

    func testAnUnsentDeleteHidesTheFile() async throws {
        let outbox = outbox()
        let source = source(outbox)
        try await source.delete(path: "Board/1. To do/existing.md", message: "Delete existing")
        let names = try await source.list("Board/1. To do").map(\.name)
        XCTAssertEqual(names, [])
        do {
            _ = try await source.readText("Board/1. To do/existing.md")
            XCTFail("a deleted file must not read")
        } catch {}
        _ = await flush(outbox)
        let writes = await remote.writes
        XCTAssertEqual(writes, ["-Board/1. To do/existing.md"])
    }
}

final class BulkReadTests: XCTestCase {
    func testGraphQLTreeAnswerBecomesFileTexts() {
        let answer = #"""
        {"data":{"repository":{"object":{"entries":[
          {"name":"A-1.md","type":"blob","object":{"text":"---\nid: A-1\n---\n","isTruncated":false}},
          {"name":"big.md","type":"blob","object":{"text":"cut","isTruncated":true}},
          {"name":"shot.png","type":"blob","object":{"text":null,"isTruncated":false}},
          {"name":"sub","type":"tree","object":{}}
        ]}}}}
        """#
        XCTAssertEqual(GitPontFileSource.texts(inGraphQLTree: Data(answer.utf8)), ["A-1.md": "---\nid: A-1\n---\n"])
        XCTAssertNil(GitPontFileSource.texts(inGraphQLTree: Data(#"{"data":{"repository":{"object":null}}}"#.utf8)))
        XCTAssertNil(GitPontFileSource.texts(inGraphQLTree: Data(#"{"errors":[{"message":"nope"}]}"#.utf8)))
    }
}
