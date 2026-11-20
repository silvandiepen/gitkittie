import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// Folder sources (no git) and review actions, end-to-end over a real temp folder laid out
/// like `~/Projects`: a `Tasks/` board whose root config sets `review_path`, and the
/// project's review requests in `<Project>/review/`.
@MainActor
final class FolderReviewTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gk-folder-\(UUID().uuidString)", isDirectory: true)
        try write("Tasks/README.md", """
        ---
        config: board
        review_path: "../../{folder}/review"
        lanes:
          - id: todo
            name: To do
            folder: "1. To do"
            status: todo
          - id: done
            name: Done
            folder: "5. Done"
            status: done
            terminal: true
        users:
          - id: sil
            github: \(NSUserName())
        ---
        """)
        try write("Tasks/Morrow/README.md", "---\nconfig: project\nproject: Morrow\nlanes: []\n---\n")
        try write("Tasks/Morrow/1. To do/MORROW-1.md", CardText.make(
            id: "MORROW-1", title: "Pets", project: "Morrow", status: "todo",
            priority: nil, type: nil, assignee: nil, order: "1", body: "# Pets"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tasks/Morrow/5. Done"), withIntermediateDirectories: true)
        try write("Morrow/review/MORROW-1-dogs/review.md", """
        ---
        config: review
        id: MORROW-1-dogs
        card: MORROW-1
        title: Dogs
        agent_only: keep
        items:
          - id: dog-v1
            file: dog-v1.png
            status: pending
            comments: []
        ---
        """)
        try write("Morrow/review/MORROW-1-dogs/dog-v1.png", "png-bytes")
        try write("Morrow/review/.hidden/review.md", "---\nitems: []\n---\n")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func entry() -> AddedRepo {
        AddedRepo(namespace: "folder", name: "Projects", branch: "", isPrivate: true,
                  boards: [SelectedBoard(folder: "Tasks/Morrow", name: "Morrow")],
                  kind: .localFolder(path: root.path, bookmark: nil))
    }

    func testLocalSourceListsAndRejectsUnsafePaths() async throws {
        let source = LocalFolderSource(root: root, securityScoped: false)
        let names = try await source.list("Morrow/review").map(\.name)
        XCTAssertEqual(names, ["MORROW-1-dogs"])
        for bad in ["../x", "/etc/passwd", "Tasks/.git/config", "a\\b"] {
            do { _ = try await source.readText(bad); XCTFail("read \(bad)") } catch {}
        }
    }

    func testVersionedWriteDetectsConflicts() async throws {
        let source = LocalFolderSource(root: root, securityScoped: false)
        let (text, version) = try await source.readVersioned("Tasks/README.md")
        try await Task.sleep(nanoseconds: 20_000_000)
        try write("Tasks/README.md", text + "\nagent edit\n")
        do {
            try await source.write(path: "Tasks/README.md", text: "mine", ifVersion: version)
            XCTFail("expected conflict")
        } catch is SourceConflictError {}
        XCTAssertTrue(try read("Tasks/README.md").hasSuffix("agent edit\n"))
        try await source.write(path: "new/file.md", text: "x", ifVersion: nil)
        XCTAssertEqual(try read("new/file.md"), "x")
    }

    func testBoardOpensOverAFolderAndLoadsItsReviews() async throws {
        let model = AppModel()
        await model.openBoard(entry(), folder: "Tasks/Morrow")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.board?.columns.first?.cards.map(\.fields.id), ["MORROW-1"])
        XCTAssertEqual(model.reviewFolder, "Morrow/review")
        XCTAssertEqual(model.reviews.map(\.id), ["MORROW-1-dogs"])
        XCTAssertEqual(model.pendingReviewCount, 1)
        XCTAssertEqual(model.reviews(for: model.board!.columns[0].cards[0]).count, 1)
        XCTAssertEqual(model.reviewerID, "sil")
        let request = model.reviews[0]
        let local = await model.localAssetURL(request, file: "dog-v1.png")
        XCTAssertEqual(local?.standardizedFileURL.path, root.appendingPathComponent("Morrow/review/MORROW-1-dogs/dog-v1.png").standardizedFileURL.path)
        model.closeRepo()
    }

    func testDecideAndCommentWriteOnlyReviewerFields() async throws {
        let model = AppModel()
        await model.openBoard(entry(), folder: "Tasks/Morrow")
        let request = model.reviews[0]
        await model.decide(request, item: request.items[0], status: .approved)
        await model.comment(model.reviews[0], item: model.reviews[0].items[0], text: "Lovely")
        XCTAssertNil(model.errorMessage)
        let item = model.reviews[0].items[0]
        XCTAssertEqual(item.status, .approved)
        XCTAssertEqual(item.decidedBy, "sil")
        XCTAssertEqual(item.comments.map(\.text), ["Lovely"])
        let onDisk = try read("Morrow/review/MORROW-1-dogs/review.md")
        XCTAssertTrue(onDisk.contains("agent_only: keep"))
        XCTAssertEqual(Review.parse(onDisk, folder: "f").items[0].status, .approved)
        model.closeRepo()
    }

    func testMarkReadWritesOnlyReadFieldsAndIndexesAttachments() async throws {
        try write("Tasks/Morrow/5. Done/MORROW-2.md", """
        ---
        id: MORROW-2
        title: Shipped
        project: Morrow
        status: done
        updated_at: 2026-11-08T10:00:00Z
        agent_field: keep
        ---
        # Shipped

        ## Activity log

        - 2026-11-08T10:00:00Z — `claude` moved it to Done
        """)
        try write("Tasks/Morrow/attachments/MORROW-2/after.png", "png")
        let model = AppModel()
        await model.openBoard(entry(), folder: "Tasks/Morrow")
        await model.loadAttachmentIndex()
        XCTAssertEqual(model.attachmentCardIDs, ["MORROW-2"])

        let done = try XCTUnwrap(BoardProgress.groups(model.board!.columns).first { $0.stage == .checkedOff })
        let card = try XCTUnwrap(done.entries.first?.card)
        XCTAssertTrue(BoardProgress.isUnread(card.fields))
        XCTAssertEqual(BoardProgress.latestActivity(card.body), "2026-11-08T10:00:00Z — `claude` moved it to Done")

        await model.markRead([card])
        XCTAssertNil(model.errorMessage)
        let reloaded = try XCTUnwrap(model.board?.columns.last?.cards.first)
        XCTAssertFalse(BoardProgress.isUnread(reloaded.fields))
        XCTAssertEqual(reloaded.fields.readBy, "sil")
        let onDisk = try read("Tasks/Morrow/5. Done/MORROW-2.md")
        XCTAssertTrue(onDisk.contains("agent_field: keep"))
        XCTAssertTrue(onDisk.contains("updated_at: 2026-11-08T10:00:00Z"))

        // An agent update after reading makes it unread again.
        try write("Tasks/Morrow/5. Done/MORROW-2.md", onDisk.replacingOccurrences(of: "updated_at: 2026-11-08T10:00:00Z", with: "updated_at: 2099-01-01T00:00:00Z"))
        await model.selectProject(model.selectedProject!)
        XCTAssertTrue(BoardProgress.isUnread(try XCTUnwrap(model.board?.columns.last?.cards.first).fields))
        model.closeRepo()
    }

    func testBoardWithoutReviewFolderShowsNoReviews() async throws {
        try write("Tasks/README.md", try read("Tasks/README.md").replacingOccurrences(of: "review_path: \"../../{folder}/review\"\n", with: ""))
        let model = AppModel()
        await model.openBoard(entry(), folder: "Tasks/Morrow")
        XCTAssertNil(model.reviewFolder)
        XCTAssertTrue(model.reviews.isEmpty)
        model.closeRepo()
    }

    func testSavedProviderReposStillDecode() throws {
        let legacy = #"[{"namespace":"sil","name":"repo","branch":"main","isPrivate":false,"boards":[]}]"#
        let decoded = try JSONDecoder().decode([AddedRepo].self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.first?.kind, .provider)
        XCTAssertEqual(decoded.first?.fullName, "sil/repo")
    }

    func testServerSourceEncodesPathsForHono() {
        let source = ServerFolderSource(baseURL: URL(string: "https://mac.ts.net")!)
        XCTAssertEqual(source.endpoint("file", path: "Tasks/1. To do/a+b.md").absoluteString,
                       "https://mac.ts.net/api/file?path=Tasks/1.%20To%20do/a%2Bb.md")
    }
}
