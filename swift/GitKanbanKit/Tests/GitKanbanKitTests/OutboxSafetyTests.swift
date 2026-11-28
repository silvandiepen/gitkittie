import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// A real folder board (`LocalFolderSource`) that records what is written to it, can
/// refuse writes, and can let "someone else" change a file between a read and a write.
private actor RecordingFolder: VersionedBoardSource {
    let folder: LocalFolderSource
    private(set) var writes: [String] = []
    private var refusing = false
    /// Run once, just before the next compare-and-swap write: another writer's change.
    private var interference: (@Sendable () throws -> Void)?

    init(root: URL) { folder = LocalFolderSource(root: root, securityScoped: false) }

    func refuse(_ on: Bool) { refusing = on }
    func interfere(_ change: @escaping @Sendable () throws -> Void) { interference = change }

    /// Refuses the way a host does when the file changed under the write.
    private func check() throws {
        if refusing { throw BoardSourceError(message: "Could not save: it changed on the server in the meantime.", isConflict: true) }
    }

    func list(_ directory: String) async throws -> [BoardFileEntry] { try await folder.list(directory) }
    func readText(_ path: String) async throws -> String { try await folder.readText(path) }
    func readData(_ path: String) async throws -> Data { try await folder.readData(path) }
    func readVersioned(_ path: String) async throws -> (text: String, version: String?) { try await folder.readVersioned(path) }

    func write(path: String, text: String, message: String) async throws {
        try check(); writes.append(path); try await folder.write(path: path, text: text, message: message)
    }
    func writeData(path: String, data: Data, message: String) async throws {
        try check(); writes.append(path); try await folder.writeData(path: path, data: data, message: message)
    }
    func delete(path: String, message: String) async throws {
        try check(); writes.append("-" + path); try await folder.delete(path: path, message: message)
    }
    func write(path: String, text: String, ifVersion version: String?) async throws {
        try check()
        if let change = interference {
            interference = nil
            try change()
        }
        try await folder.write(path: path, text: text, ifVersion: version)
        writes.append(path)
    }
}

final class OutboxSafetyTests: XCTestCase {
    private var directory: URL!
    private var board: URL!
    private var remote: RecordingFolder!
    private let path = "Lobby/review/LOBBY-001-first-decisions/review.md"

    /// When the reviewer worked offline (24 Nov), an older answer on the server (20 Nov)
    /// and a newer one given on another device (25 Nov).
    private let queuedAt = date("2026-11-24T15:27:00Z")
    private let olderAt = date("2026-11-20T10:00:00Z")
    private let newerAt = date("2026-11-25T09:00:00Z")

    private static func date(_ text: String) -> Date { Review.reviewDate(text)! }

    private let request = """
    ---
    config: review
    id: LOBBY-001-first-decisions
    project: Lobby
    title: First decisions
    requested_by: claude
    requested_at: 2026-11-20T09:00:00Z
    custom_key: keep me
    items:
      - id: hero-1
        file: hero.png
        status: pending
        comments: []
    questions:
      - id: q-storage
        question: Where do files live?
        select: one
        options:
          - id: icloud
            label: iCloud
          - id: local
            label: Local only
        answer: []
        answer_other: null
        answered_by: null
        answered_at: null
        comments: []
        handled_at: null
      - id: q-name
        question: What is it called?
        select: one
        options:
          - id: lobby
            label: Lobby
          - id: foyer
            label: Foyer
        answer: []
        answer_other: null
        answered_by: null
        answered_at: null
        comments: []
        handled_at: null
    ---

    Notes from the agent.

    """

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("gk-outbox-safety-\(UUID().uuidString)", isDirectory: true)
        board = directory.appendingPathComponent("Board", isDirectory: true)
        try serverWrite(request)
        remote = RecordingFolder(root: board)
    }

    override func tearDown() async throws {
        // An unwritable folder from a test has to be writable again to be removed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outboxURL.path)
        try FileManager.default.removeItem(at: directory)
    }

    private var outboxURL: URL { directory.appendingPathComponent("Outbox", isDirectory: true) }
    private func outbox() -> Outbox { Outbox(directory: outboxURL) }

    private func source(_ outbox: Outbox) -> OutboxSource {
        OutboxSource(base: remote, outbox: outbox, repoKey: "repo",
                     cache: ReadCache(directory: directory.appendingPathComponent("Cache")), saved: {})
    }

    private func flush(_ outbox: Outbox) async -> Int {
        let remote = remote!
        return await outbox.flush(resolve: { _ in remote }, changed: {})
    }

    private func serverText() throws -> String {
        try String(contentsOf: board.appendingPathComponent(path), encoding: .utf8)
    }

    private func serverWrite(_ text: String) throws {
        let url = board.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// What the app does when the reviewer acts: apply onto what it reads, queue with the edits.
    private func review(_ source: OutboxSource, _ edits: [ReviewEdit]) async throws {
        let text = try await source.readText(path)
        try await source.writeReview(path: path, text: try Review.apply(text, edits: edits), edits: edits,
                                     message: "Review LOBBY-001-first-decisions")
    }

    // MARK: Nothing is queued without its content

    func testABlobThatCannotBeWrittenThrowsAndQueuesNothing() async throws {
        let outbox = outbox()
        let source = source(outbox)
        try FileManager.default.createDirectory(at: outboxURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: outboxURL.path)

        do {
            try await source.write(path: "Board/1. To do/new.md", text: "hello", message: "Add task new")
            XCTFail("a write whose content cannot be stored must throw")
        } catch let error as OutboxError {
            guard case .notSaved(let failedPath, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(failedPath, "Board/1. To do/new.md")
            XCTAssertTrue(error.localizedDescription.hasPrefix("Not saved:"))
        }

        let queued = await outbox.operations()
        XCTAssertEqual(queued, [], "nothing is queued")
        let files = try FileManager.default.contentsOfDirectory(atPath: outboxURL.path)
        XCTAssertFalse(files.contains { $0.hasSuffix(".blob") }, "no content left behind")
        XCTAssertFalse(files.contains("outbox.json"), "no index entry without its content")
    }

    func testAnIndexThatCannotBeReadIsNeverOverwritten() async throws {
        let outbox = outbox()
        let source = source(outbox)
        try FileManager.default.createDirectory(at: outboxURL, withIntermediateDirectories: true)
        let garbage = Data("[{\"id\": \"half-written".utf8)
        try garbage.write(to: outboxURL.appendingPathComponent("outbox.json"))

        do {
            try await source.write(path: "Board/1. To do/new.md", text: "hello", message: "Add task new")
            XCTFail("a write that cannot be listed must throw")
        } catch let error as OutboxError {
            guard case .notSaved = error else { return XCTFail("unexpected \(error)") }
        }
        let after = try Data(contentsOf: outboxURL.appendingPathComponent("outbox.json"))
        XCTAssertEqual(after, garbage, "the unreadable list is left as it is, not replaced by an empty one")
        let files = try FileManager.default.contentsOfDirectory(atPath: outboxURL.path)
        XCTAssertFalse(files.contains { $0.hasSuffix(".blob") }, "the content of the write that was not queued is removed")
    }

    // MARK: Review requests merge instead of overwriting

    func testAReviewConflictReappliesTheReviewersChangesAndKeepsANewerServerAnswer() async throws {
        let outbox = outbox()
        let source = source(outbox)
        // Offline on 24 Nov: approve, comment, answer both questions.
        try await review(source, [
            .decision(item: "hero-1", status: .approved, by: "sil", at: queuedAt),
            .comment(item: "hero-1", by: "sil", text: "Lovely", image: nil, at: queuedAt),
            .answer(question: "q-storage", choices: ["icloud"], other: nil, by: "sil", at: queuedAt),
            .answer(question: "q-name", choices: ["lobby"], other: nil, by: "sil", at: queuedAt),
        ])

        // Meanwhile on the server: the agent added a round, the storage question was
        // answered again on another device (newer), and the name question has an older answer.
        var server = try serverText()
        server = try Review.appendItems(server, [Review.NewItem(id: "hero-2", file: "hero-2.png")])
        server = try Review.applyAnswer(server, questionID: "q-storage", choices: ["local"], other: nil, by: "sil", at: newerAt)
        server = try Review.applyAnswer(server, questionID: "q-name", choices: ["foyer"], other: nil, by: "sil", at: olderAt)
        try serverWrite(server)

        // Before it is sent, reads show the server's copy with the queued edits on top.
        let shown = Review.parse(try await source.readText(path), folder: "")
        XCTAssertEqual(shown.items.map(\.id), ["hero-1", "hero-2"])
        XCTAssertEqual(shown.questions.first { $0.id == "q-storage" }?.answer, ["local"])

        let sent = await flush(outbox)
        XCTAssertEqual(sent, 1)

        let text = try serverText()
        let result = Review.parse(text, folder: "")
        let hero = try XCTUnwrap(result.items.first { $0.id == "hero-1" })
        XCTAssertEqual(hero.status, .approved)
        XCTAssertEqual(hero.decidedAt, "2026-11-24T15:27:00Z")
        XCTAssertEqual(hero.comments.map(\.text), ["Lovely"])
        XCTAssertNotNil(result.items.first { $0.id == "hero-2" }, "the agent's new round is kept")
        let storage = try XCTUnwrap(result.questions.first { $0.id == "q-storage" })
        XCTAssertEqual(storage.answer, ["local"], "the newer answer on the server wins over the older queued one")
        XCTAssertEqual(storage.answeredAt, "2026-11-25T09:00:00Z")
        let name = try XCTUnwrap(result.questions.first { $0.id == "q-name" })
        XCTAssertEqual(name.answer, ["lobby"], "the queued answer wins over an older one on the server")
        XCTAssertTrue(text.contains("custom_key: keep me"))
        XCTAssertTrue(text.hasSuffix("---\n\nNotes from the agent.\n"), "the body is left as it was")

        let receipts = await outbox.receipts()
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipt.note, "Left out because the server has something newer: answer to q-storage.")
    }

    func testAChangeMadeBetweenReadAndWriteIsReadAgainNotOverwritten() async throws {
        let outbox = outbox()
        let source = source(outbox)
        try await review(source, [.comment(item: "hero-1", by: "sil", text: "Brighter, please", image: nil, at: queuedAt)])

        let board = board!, path = path
        await remote.interfere {
            let url = board.appendingPathComponent(path)
            let text = try String(contentsOf: url, encoding: .utf8)
            try Data(try Review.appendItems(text, [Review.NewItem(id: "hero-3", file: "hero-3.png")]).utf8).write(to: url, options: .atomic)
        }
        let sent = await flush(outbox)
        XCTAssertEqual(sent, 1)
        let result = Review.parse(try serverText(), folder: "")
        XCTAssertNotNil(result.items.first { $0.id == "hero-3" }, "the change made in between is kept")
        XCTAssertEqual(result.items.first { $0.id == "hero-1" }?.comments.map(\.text), ["Brighter, please"])
    }

    /// A decision queued before the agent acted on the item (and put it back to pending)
    /// is left out; one made after goes in. An answer the agent has handled is locked.
    func testADecisionOlderThanTheAgentsHandlingIsLeftOutAndANewerOneGoesIn() throws {
        var server = try Review.applyAnswer(request, questionID: "q-name", choices: ["lobby"], other: nil, by: "sil", at: olderAt)
        // The agent handled q-name, and put hero-1 back to pending for a second look, on 22 Nov.
        server = try Review.markHandled(server, itemID: "hero-1", shippedTo: nil, at: Self.date("2026-11-22T10:00:00Z"))
        server = try Review.markQuestionHandled(server, questionID: "q-name", at: Self.date("2026-11-22T10:00:00Z"))
        XCTAssertEqual(Review.parse(server, folder: "").items.first?.handledAt, "2026-11-22T10:00:00Z")

        // Queued on 20 Nov, before the agent acted: left out.
        let stale = try Review.merge(server, edits: [
            .decision(item: "hero-1", status: .approved, by: "sil", at: olderAt),
            .answer(question: "q-name", choices: ["foyer"], other: nil, by: "sil", at: queuedAt),
        ])
        XCTAssertEqual(Review.parse(stale.text, folder: "").items.first?.status, .pending)
        XCTAssertEqual(Review.parse(stale.text, folder: "").questions.first { $0.id == "q-name" }?.answer, ["lobby"],
                       "a handled answer is locked")
        XCTAssertEqual(stale.superseded.count, 2)

        // Decided on 24 Nov, after the agent's second look: goes in.
        let fresh = try Review.merge(server, edits: [.decision(item: "hero-1", status: .rejected, by: "sil", at: queuedAt)])
        XCTAssertEqual(Review.parse(fresh.text, folder: "").items.first?.status, .rejected)
        XCTAssertEqual(fresh.applied.count, 1)
    }

    func testSeveralQueuedWritesToOneRequestAreFoldedIntoOne() async throws {
        let outbox = outbox()
        let source = source(outbox)
        try await review(source, [.comment(item: "hero-1", by: "sil", text: "First", image: nil, at: queuedAt)])
        try await review(source, [.decision(item: "hero-1", status: .changesRequested, by: "sil", at: queuedAt.addingTimeInterval(5))])
        try await review(source, [.answer(question: "q-name", choices: ["foyer"], other: nil, by: "sil", at: queuedAt.addingTimeInterval(9))])
        // A write queued by an earlier version: only the whole file, no edits.
        let snapshot = try Review.appendComment(try await source.readText(path), itemID: "hero-1", by: "sil", body: "Second",
                                                at: queuedAt.addingTimeInterval(12))
        try await outbox.enqueue(repoKey: "repo", kind: .write, path: path, message: "Review LOBBY-001-first-decisions",
                                 data: Data(snapshot.utf8))
        let queued = await outbox.operations()
        XCTAssertEqual(queued.count, 4)

        let sent = await flush(outbox)
        XCTAssertEqual(sent, 4, "every queued write to the request went out")
        let writes = await remote.writes
        XCTAssertEqual(writes, [path], "in a single write")
        let left = await outbox.operations()
        XCTAssertEqual(left, [])

        let result = Review.parse(try serverText(), folder: "")
        let hero = try XCTUnwrap(result.items.first { $0.id == "hero-1" })
        XCTAssertEqual(hero.status, .changesRequested)
        XCTAssertEqual(hero.comments.map(\.text), ["First", "Second"], "each comment once")
        XCTAssertEqual(result.questions.first { $0.id == "q-name" }?.answer, ["foyer"])
    }

    func testAnAnswerChangedTwiceInOneSecondEndsAsTheLastOne() async throws {
        let outbox = outbox()
        let source = source(outbox)
        try await review(source, [.answer(question: "q-name", choices: ["lobby"], other: nil, by: "sil", at: queuedAt)])
        try await review(source, [.answer(question: "q-name", choices: ["foyer"], other: nil, by: "sil", at: queuedAt)])
        _ = await flush(outbox)
        let result = Review.parse(try serverText(), folder: "")
        XCTAssertEqual(result.questions.first { $0.id == "q-name" }?.answer, ["foyer"])
    }

    /// Sil's LOBBY-001: one refused write followed by later ones to the same request, all
    /// whole copies from before the outbox kept edits.
    func testARefusedReviewWriteDoesNotHoldBackLaterOnesAndCanBeRetriedSafely() async throws {
        let outbox = outbox()
        let first = try Review.applyAnswer(request, questionID: "q-storage", choices: ["icloud"], other: nil, by: "sil", at: queuedAt)
        try await outbox.enqueue(repoKey: "repo", kind: .write, path: path, message: "Review", data: Data(first.utf8))
        await remote.refuse(true)
        _ = await flush(outbox)
        let refused = await outbox.operations()
        XCTAssertEqual(refused.map(\.state), [.failed])

        let second = try Review.applyDecision(first, itemID: "hero-1", status: .approved, by: "sil", at: queuedAt.addingTimeInterval(30))
        try await outbox.enqueue(repoKey: "repo", kind: .write, path: path, message: "Review", data: Data(second.utf8))
        let third = try Review.applyAnswer(second, questionID: "q-name", choices: ["lobby"], other: nil, by: "sil", at: queuedAt.addingTimeInterval(60))
        try await outbox.enqueue(repoKey: "repo", kind: .write, path: path, message: "Review", data: Data(third.utf8))

        // The next day the storage question is answered again on the server.
        try serverWrite(try Review.applyAnswer(try serverText(), questionID: "q-storage", choices: ["local"], other: nil, by: "sil", at: newerAt))

        await remote.refuse(false)
        let sent = await flush(outbox)
        XCTAssertEqual(sent, 2, "the later writes are not blocked by the refused one")
        var result = Review.parse(try serverText(), folder: "")
        XCTAssertEqual(result.items.first?.status, .approved)
        XCTAssertEqual(result.questions.first { $0.id == "q-name" }?.answer, ["lobby"])
        XCTAssertEqual(result.questions.first { $0.id == "q-storage" }?.answer, ["local"], "the newer answer is not overwritten")

        let stillRefused = await outbox.operations()
        XCTAssertEqual(stillRefused.map(\.state), [.failed])
        try await outbox.retry(stillRefused[0].id)
        let retried = await flush(outbox)
        XCTAssertEqual(retried, 1)
        result = Review.parse(try serverText(), folder: "")
        XCTAssertEqual(result.questions.first { $0.id == "q-storage" }?.answer, ["local"], "a retry cannot overwrite the newer answer either")
        let receipts = await outbox.receipts()
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipt.note, "The server already had these changes. Left out because the server has something newer: answer to q-storage.")
    }

    /// Sil's ARVIK-471: a write listed without its content.
    func testAReviewWriteWithoutContentFailsClearlyAndDoesNotHideTheRequest() async throws {
        let outbox = outbox()
        let source = source(outbox)
        let queued = try await outbox.enqueue(repoKey: "repo", kind: .write, path: path, message: "Review", data: Data(request.utf8))
        try FileManager.default.removeItem(at: outboxURL.appendingPathComponent(queued.blobName))

        let text = try await source.readText(path)
        XCTAssertEqual(text, request, "the request still reads, from the server")
        let sent = await flush(outbox)
        XCTAssertEqual(sent, 0)
        let after = await outbox.operations()
        XCTAssertEqual(after.map(\.state), [.failed])
        XCTAssertEqual(after.first?.note, OutboxError.contentMissing(path: path).errorDescription)
        let writes = await remote.writes
        XCTAssertEqual(writes, [])
    }

    // MARK: Cards keep the conflict

    func testACardConflictStaysRefusedWithAnActionableNote() async throws {
        let outbox = outbox()
        let source = source(outbox)
        try await source.write(path: "Lobby/1. To do/a.md", text: "one", message: "Update a")
        try await source.write(path: "Lobby/1. To do/a.md", text: "two", message: "Update a again")
        await remote.refuse(true)
        _ = await flush(outbox)
        let after = await outbox.operations()
        XCTAssertEqual(after.map(\.state), [.failed, .pending], "a card is not merged: the later write waits behind the refused one")
        let note = try XCTUnwrap(after.first?.note)
        XCTAssertTrue(note.contains("Retry sends your version"), note)
        XCTAssertTrue(note.contains("Discard keeps the server's"), note)
        XCTAssertTrue(note.contains("Show What It Was"), note)
    }
}
