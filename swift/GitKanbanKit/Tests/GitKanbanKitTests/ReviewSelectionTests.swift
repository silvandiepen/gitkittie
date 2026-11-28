import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// The folder board as the server: a real `LocalFolderSource` that counts the writes reaching it.
private actor CountingFolder: VersionedBoardSource {
    let folder: LocalFolderSource
    private(set) var writes: [String] = []

    init(root: URL) { folder = LocalFolderSource(root: root, securityScoped: false) }

    func list(_ directory: String) async throws -> [BoardFileEntry] { try await folder.list(directory) }
    func readText(_ path: String) async throws -> String { try await folder.readText(path) }
    func readData(_ path: String) async throws -> Data { try await folder.readData(path) }
    func readVersioned(_ path: String) async throws -> (text: String, version: String?) { try await folder.readVersioned(path) }
    func write(path: String, text: String, message: String) async throws {
        writes.append(path); try await folder.write(path: path, text: text, message: message)
    }
    func writeData(path: String, data: Data, message: String) async throws {
        writes.append(path); try await folder.writeData(path: path, data: data, message: message)
    }
    func delete(path: String, message: String) async throws {
        writes.append("-" + path); try await folder.delete(path: path, message: message)
    }
    func write(path: String, text: String, ifVersion version: String?) async throws {
        writes.append(path); try await folder.write(path: path, text: text, ifVersion: version)
    }
}

/// Choosing several files of a request and deciding or commenting on them at once, through
/// the app model, over a real temporary folder board. Writes go through the outbox the way
/// they do for a repository, so what is queued and what reaches the folder can be checked.
@MainActor
final class ReviewSelectionTests: XCTestCase {
    private var root: URL!
    private var board: URL!
    private var suite: String!
    private var remote: CountingFolder!
    private let icons = "Tasks/Mail/review/MAIL-1-icons/review.md"
    private let dogs = "Tasks/Mail/review/MAIL-2-dogs/review.md"

    override func setUp() async throws {
        suite = "git093-review-selection-\(UUID().uuidString)"
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        board = root.appendingPathComponent("Board", isDirectory: true)
        try write("Tasks/README.md", """
        ---
        config: board
        review_path: review
        lanes:
          - id: todo
            name: To do
            folder: "1. To do"
            status: todo
        users:
          - id: sil
            github: \(NSUserName())
        ---
        """)
        try write("Tasks/Mail/README.md", "---\nconfig: project\nproject: Mail\nlanes: []\n---\n")
        try FileManager.default.createDirectory(at: board.appendingPathComponent("Tasks/Mail/1. To do"), withIntermediateDirectories: true)
        try write(icons, """
        ---
        config: review
        id: MAIL-1-icons
        title: Icons
        agent_only: keep
        items:
          - id: icon-a
            file: a.png
            status: pending
            comments: []
          - id: icon-b
            file: b.png
            status: pending
            comments: []
          - id: icon-c
            file: c.png
            status: pending
            comments: []
          - id: icon-old
            file: old.png
            status: approved
            decided_by: sil
            decided_at: 2026-11-20T10:00:00Z
            comments: []
        ---

        Notes from the agent.
        """)
        try write(dogs, """
        ---
        config: review
        id: MAIL-2-dogs
        title: Dogs
        items:
          - id: dog-v1
            file: dog-v1.png
            group: dog
            pick: one
            status: pending
            comments: []
          - id: dog-v2
            file: dog-v2.png
            group: dog
            pick: one
            status: pending
            comments: []
          - id: cat
            file: cat.png
            status: pending
            comments: []
        ---
        """)
        remote = CountingFolder(root: board)
    }

    override func tearDown() async throws {
        AppModel.removeTestStorage(suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = board.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func server(_ path: String) throws -> ReviewRequest {
        Review.parse(try String(contentsOf: board.appendingPathComponent(path), encoding: .utf8), folder: "f")
    }

    /// The folder board opened in the app, its writes going through the outbox as a repository's do.
    private func open() async throws -> AppModel {
        let model = AppModel.testing(suite: suite, keychainService: suite)
        let entry = AddedRepo(namespace: "folder", name: "Projects", branch: "", isPrivate: true,
                              boards: [SelectedBoard(folder: "Tasks/Mail", name: "Mail")],
                              kind: .localFolder(path: board.path, bookmark: nil))
        await model.openBoard(entry, folder: "Tasks/Mail")
        XCTAssertNil(model.errorMessage)
        model.source = OutboxSource(base: remote, outbox: model.outbox, repoKey: entry.id,
                                    cache: ReadCache(directory: AppModel.testStorage(suite).appendingPathComponent("Cache")), saved: {})
        XCTAssertEqual(model.reviews.map(\.id).sorted(), ["MAIL-1-icons", "MAIL-2-dogs"])
        return model
    }

    private func request(_ model: AppModel, _ id: String) throws -> ReviewRequest {
        try XCTUnwrap(model.reviews.first { $0.id == id })
    }

    private func flush(_ model: AppModel) async -> Int {
        let remote = remote!
        return await model.outbox.flush(resolve: { _ in remote }, changed: {})
    }

    // MARK: ⌘A, then one action

    func testSelectAllThenApproveDecidesEveryShownFileInOneWrite() async throws {
        let model = try await open()
        let icons = try request(model, "MAIL-1-icons")
        // ⌘A with Only Waiting on takes what the request view shows: the already approved file is hidden.
        let selected = icons.shownItemIDs(hiding: icons.settledIDs.items)
        XCTAssertEqual(selected, ["icon-a", "icon-b", "icon-c"])

        let written = await model.decide(icons, itemIDs: selected, status: .approved)
        XCTAssertTrue(written)
        XCTAssertNil(model.errorMessage)

        let queued = await model.outbox.operations()
        XCTAssertEqual(queued.count, 1, "one action on the selection is one entry in the outbox")
        XCTAssertEqual(queued.first?.review?.count, 3, "with an edit per selected file")
        XCTAssertEqual(try request(model, "MAIL-1-icons").items.map(\.status), [.approved, .approved, .approved, .approved],
                       "the request shows the decision before it is sent")

        let sent = await flush(model)
        XCTAssertEqual(sent, 1)
        let writes = await remote.writes
        XCTAssertEqual(writes, [self.icons], "in a single write")
        let result = try server(self.icons)
        XCTAssertEqual(result.items.map(\.status), [.approved, .approved, .approved, .approved])
        XCTAssertEqual(Set(result.items.prefix(3).map(\.decidedBy)), ["sil"])
        XCTAssertEqual(result.items.last?.decidedAt, "2026-11-20T10:00:00Z", "a file not selected is left as it was")
        let text = try String(contentsOf: board.appendingPathComponent(self.icons), encoding: .utf8)
        XCTAssertTrue(text.contains("agent_only: keep"))
        XCTAssertTrue(text.hasSuffix("Notes from the agent.\n") || text.hasSuffix("Notes from the agent."))
    }

    func testEveryDecisionWorksOnASelectionAndSkipsFilesThatAlreadyHaveIt() async throws {
        let model = try await open()
        await model.decide(try request(model, "MAIL-1-icons"), itemIDs: ["icon-a", "icon-b"], status: .changesRequested, comment: "Rounder")
        await model.decide(try request(model, "MAIL-1-icons"), itemIDs: ["icon-b", "icon-c"], status: .rejected)
        XCTAssertEqual(try request(model, "MAIL-1-icons").items.map(\.status), [.changesRequested, .rejected, .rejected, .approved])
        // Back to Waiting on everything: icon-old goes back too; nothing to change is no write.
        await model.decide(try request(model, "MAIL-1-icons"), itemIDs: ["icon-a", "icon-b", "icon-c", "icon-old", "missing"], status: .pending)
        let before = await model.outbox.operations().count
        let unchanged = await model.decide(try request(model, "MAIL-1-icons"), itemIDs: ["icon-a"], status: .pending)
        XCTAssertTrue(unchanged)
        let after = await model.outbox.operations().count
        XCTAssertEqual(after, before, "a decision every selected file already has writes nothing")
        XCTAssertNil(model.errorMessage)

        _ = await flush(model)
        let result = try server(icons)
        XCTAssertEqual(result.items.map(\.status), [.pending, .pending, .pending, .pending])
        XCTAssertTrue(result.items.allSatisfy { $0.decidedBy == nil && $0.decidedAt == nil })
    }

    // MARK: Comment on the selection

    func testACommentReachesOnlyTheSelectedFiles() async throws {
        let model = try await open()
        let written = await model.comment(try request(model, "MAIL-1-icons"), itemIDs: ["icon-a", "icon-c"], text: "  Thinner lines, please  ")
        XCTAssertTrue(written)
        let queued = await model.outbox.operations()
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.review?.count, 2)

        _ = await flush(model)
        let result = try server(icons)
        XCTAssertEqual(result.items.map { $0.comments.map(\.text) }, [["Thinner lines, please"], [], ["Thinner lines, please"], []])
        XCTAssertEqual(result.items.map(\.status), [.pending, .pending, .pending, .approved], "a comment decides nothing")

        let empty = await model.comment(try request(model, "MAIL-1-icons"), itemIDs: ["icon-b"], text: "   ")
        XCTAssertFalse(empty, "an empty comment is not written")
        let none = await model.comment(try request(model, "MAIL-1-icons"), itemIDs: [String](), text: "Hello")
        XCTAssertFalse(none, "nor is a comment on nothing")
        let left = await model.outbox.operations()
        XCTAssertEqual(left, [])
    }

    // MARK: Pick one

    func testApprovingTwoOptionsOfAPickOneGroupIsRefusedWithAMessage() async throws {
        let model = try await open()
        let dogs = try request(model, "MAIL-2-dogs")
        let refused = await model.decide(dogs, itemIDs: dogs.shownItemIDs(), status: .approved)
        XCTAssertFalse(refused)
        XCTAssertEqual(model.errorMessage, "“dog” is pick one: approve only one of its options, not dog-v1 and dog-v2.")
        let queued = await model.outbox.operations()
        XCTAssertEqual(queued, [], "nothing is written, not even the file outside the group")

        // One option and a file outside the group is fine.
        let picked = await model.decide(try request(model, "MAIL-2-dogs"), itemIDs: ["dog-v1", "cat"], status: .approved)
        XCTAssertTrue(picked)
        XCTAssertNil(model.errorMessage)
        // With one already approved, approving the other is refused too.
        let second = await model.decide(try request(model, "MAIL-2-dogs"), itemIDs: ["dog-v2"], status: .approved)
        XCTAssertFalse(second)
        XCTAssertEqual(model.errorMessage, "“dog” is pick one: approve only one of its options, not dog-v1 and dog-v2.")
        // Rejecting both options is not a choice between them, so it goes in.
        let rejected = await model.decide(try request(model, "MAIL-2-dogs"), itemIDs: ["dog-v1", "dog-v2"], status: .rejected)
        XCTAssertTrue(rejected)

        _ = await flush(model)
        XCTAssertEqual(try server(self.dogs).items.map(\.status), [.rejected, .rejected, .approved])
    }

    // MARK: Merging onto a changed server file

    func testTheQueuedSelectionMergesOntoAServerFileThatChanged() async throws {
        let model = try await open()
        let icons = try request(model, "MAIL-1-icons")
        await model.decide(icons, itemIDs: ["icon-a", "icon-b", "icon-c"], status: .changesRequested, comment: "Smaller")
        await model.comment(try request(model, "MAIL-1-icons"), itemIDs: ["icon-a", "icon-b"], text: "Rounder")
        let queued = await model.outbox.operations()
        XCTAssertEqual(queued.count, 2)

        // Before it is sent, the agent adds a round and comments on icon-a on the server.
        let url = board.appendingPathComponent(self.icons)
        var text = try String(contentsOf: url, encoding: .utf8)
        text = try Review.appendItems(text, [Review.NewItem(id: "icon-d", file: "d.png")])
        text = try Review.appendComment(text, itemID: "icon-a", by: "claude", body: "Working on it", at: Date(timeIntervalSince1970: 1_700_000_000))
        try Data(text.utf8).write(to: url, options: .atomic)

        let sent = await flush(model)
        XCTAssertEqual(sent, 2)
        let writes = await remote.writes
        XCTAssertEqual(writes, [self.icons], "both queued selection writes go out as one")
        let result = try server(self.icons)
        XCTAssertEqual(result.items.map(\.id), ["icon-a", "icon-b", "icon-c", "icon-old", "icon-d"], "the agent's new round is kept")
        XCTAssertEqual(result.items.map(\.status), [.changesRequested, .changesRequested, .changesRequested, .approved, .pending])
        XCTAssertEqual(result.items[0].comments.map(\.text), ["Working on it", "Smaller", "Rounder"], "the agent's comment is kept, the reviewer's added")
        XCTAssertEqual(result.items[1].comments.map(\.text), ["Smaller", "Rounder"])
        XCTAssertEqual(result.items[2].comments.map(\.text), ["Smaller"], "asking for changes carries its comment")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("agent_only: keep"))
    }
}
