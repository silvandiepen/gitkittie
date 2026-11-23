import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// A board's documentation pages over a real temp folder: read, search, write and delete,
/// the way an agent does it.
@MainActor
final class BoardDocsTests: XCTestCase {
    private var root: URL!
    private var board: AgentBoard!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gk-docs-\(UUID().uuidString)", isDirectory: true)
        try write("README.md", "---\nconfig: board\nlanes:\n  - id: todo\n    name: To do\n    folder: \"1. To do\"\n    status: todo\n---\n")
        try write("Pets/README.md", "---\nconfig: project\nproject: Pets\nicon: \"pawprint.fill\"\nlanes: []\n---\n\nA game about pets.\n")
        try write("Pets/1. To do/PETS-001-dogs.md", CardText.make(id: "PETS-001", title: "Dogs", project: "Pets", status: "todo"))
        try write("Pets/docs/camera-rules.md", "# Camera rules\n\nIntro.\n\n## Height\n\nThe camera stays at the chosen height.\n")
        try write("Pets/docs/notes.txt", "not a page")
        board = AgentBoard(source: LocalFolderSource(root: root, securityScoped: false), folder: "Pets")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }

    func testPagesAreTheReadmeTextAndTheDocsFolder() async throws {
        let pages = await BoardDocs.load(source: board.source, boardFolder: "Pets")
        XCTAssertEqual(pages.map(\.path), ["README.md", "docs/camera-rules.md"])
        XCTAssertEqual(pages.map(\.title), ["About", "Camera rules"])
        XCTAssertEqual(pages[0].text, "A game about pets.\n")
    }

    func testTheDocsFolderIsNotACard() async throws {
        let listing = try await RemoteBoardStore.listing(source: board.source, folder: "Pets")
        XCTAssertEqual(listing.files.values.flatMap { $0 }, ["PETS-001-dogs.md"])
    }

    func testSearchFindsLinesWithTheirHeading() async throws {
        let hits = (await board.searchDocs("camera height"))["hits"] as? [[String: Any]] ?? []
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?["path"] as? String, "docs/camera-rules.md")
        XCTAssertEqual(hits.first?["heading"] as? String, "Height")
        XCTAssertEqual(hits.first?["line"] as? String, "The camera stays at the chosen height.")
        let byTitle = (await board.searchDocs("about"))["hits"] as? [[String: Any]] ?? []
        XCTAssertEqual(byTitle.first?["path"] as? String, "README.md")
    }

    func testAnAgentCreatesReplacesAndDeletesAPage() async throws {
        let made = try await board.writeDoc(path: nil, title: "Release plan", text: "Ship in May.", replaces: nil, agent: "claude")
        XCTAssertEqual(made["path"] as? String, "docs/release-plan.md")
        XCTAssertEqual(try read("Pets/docs/release-plan.md"), "# Release plan\n\nShip in May.\n")

        // Replacing needs the text that was read.
        do {
            _ = try await board.writeDoc(path: "docs/release-plan.md", title: nil, text: "x", replaces: nil, agent: nil)
            XCTFail("replaced without having read")
        } catch let error as AgentBoardError { XCTAssertTrue(error.message.contains("replaces")) }
        do {
            _ = try await board.writeDoc(path: "release-plan", title: nil, text: "x", replaces: "something else", agent: nil)
            XCTFail("replaced a page that changed")
        } catch let error as AgentBoardError { XCTAssertTrue(error.message.contains("changed since")) }

        let current = try await board.getDoc("docs/release-plan.md")["text"] as? String
        _ = try await board.writeDoc(path: "docs/release-plan.md", title: nil, text: "# Release plan\n\nShip in June.", replaces: current, agent: nil)
        XCTAssertEqual(try read("Pets/docs/release-plan.md"), "# Release plan\n\nShip in June.\n")

        _ = try await board.deleteDoc("release-plan")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Pets/docs/release-plan.md").path))
    }

    func testWritingAboutKeepsTheBoardConfiguration() async throws {
        let current = try await board.getDoc("README.md")["text"] as? String
        _ = try await board.writeDoc(path: "README.md", title: nil, text: "A game about pets and their people.", replaces: current, agent: nil)
        let readme = try read("Pets/README.md")
        XCTAssertTrue(readme.contains("icon: \"pawprint.fill\""))
        XCTAssertTrue(readme.contains("project: Pets"))
        XCTAssertTrue(readme.hasSuffix("A game about pets and their people.\n"))
        do { _ = try await board.deleteDoc("README.md"); XCTFail("deleted the README") } catch {}
    }

    func testPathsOutsideDocsAreRefused() async throws {
        for bad in ["../README.md", "docs/sub/page.md", "1. To do/PETS-001-dogs.md"] {
            do { _ = try await board.getDoc(bad); XCTFail("\(bad) was accepted") } catch {}
        }
    }

    // MARK: Linked folders

    func testLinkedFoldersAreNamedInTheReadme() throws {
        let readme = "---\nconfig: project\nproject: Pets\ndocs:\n  - \"octo/pets:docs\"\n  - octo/site:content/handbook @next readonly\nlanes: []\n---\n\nAbout.\n"
        let sources = BoardDocs.sources(inReadme: readme)
        XCTAssertEqual(sources, [DocSource(repo: "octo/pets", folder: "docs"),
                                 DocSource(repo: "octo/site", folder: "content/handbook", branch: "next", editable: false)])
        XCTAssertEqual(BoardDocs.sources(inReadme: "---\ndocs: octo/pets/docs\n---\n"), [DocSource(repo: "octo/pets", folder: "docs")])
        XCTAssertEqual(DocSource(written: "group/sub/repo:docs")?.owner, "group/sub")
        XCTAssertNil(DocSource(written: "just-a-name"))

        // Writing the list back keeps every other line.
        let fewer = BoardDocs.setting([sources[1]], inReadme: readme)
        XCTAssertEqual(fewer, "---\nconfig: project\nproject: Pets\nlanes: []\ndocs:\n  - \"octo/site:content/handbook @next readonly\"\n---\n\nAbout.\n")
        XCTAssertEqual(BoardDocs.sources(inReadme: fewer), [sources[1]])
        XCTAssertFalse(BoardDocs.setting([], inReadme: readme).contains("docs:"))
    }

    func testALinkedFolderIsListedWithSubfoldersAndReadWhenAsked() async throws {
        // Another "repository": a second folder on disk.
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("gk-linked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: other) }
        for (path, text) in ["docs/overview.md": "# Overview\n\nThe game.\n", "docs/systems/camera.md": "# Camera\n\nStays at the chosen height.\n",
                             "docs/systems/notes.txt": "x", "docs/.hidden/secret.md": "no"] {
            let url = other.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let through = LocalFolderSource(root: other, securityScoped: false)
        let linked = DocSource(repo: "octo/pets", folder: "docs")
        try write("Pets/README.md", "---\nconfig: project\nproject: Pets\ndocs:\n  - \"octo/pets:docs readonly\"\nlanes: []\n---\n")
        board.linkedSource = { asked in asked.id == linked.id ? through : nil }

        let listed = (await board.listDocs())["docs"] as? [[String: Any]] ?? []
        XCTAssertEqual(listed.compactMap { $0["path"] as? String }, ["docs/camera-rules.md", "octo/pets:docs/overview.md", "octo/pets:docs/systems/camera.md"])
        XCTAssertEqual(listed.last?["editable"] as? Bool, false)

        let page = try await board.getDoc("octo/pets:docs/systems/camera.md")
        XCTAssertEqual(page["title"] as? String, "Camera")
        XCTAssertEqual(page["text"] as? String, "# Camera\n\nStays at the chosen height.\n")

        let hits = (await board.searchDocs("chosen height"))["hits"] as? [[String: Any]] ?? []
        XCTAssertEqual(Set(hits.compactMap { $0["path"] as? String }), ["docs/camera-rules.md", "octo/pets:docs/systems/camera.md"])

        // A folder the board marks read-only is not written to.
        do {
            _ = try await board.writeDoc(path: "octo/pets:docs/overview.md", title: nil, text: "x", replaces: "# Overview\n\nThe game.\n", agent: nil)
            XCTFail("wrote to a read-only linked folder")
        } catch let error as AgentBoardError { XCTAssertTrue(error.message.contains("read-only")) }
    }

    // MARK: Saving settings keeps the rest of the README

    func testPatchingReplacesOnlyTheNamedParts() {
        let original = """
        ---
        config: board
        project: Pets
        repository: octo/pets
        epics:
          - id: dogs
            name: Dogs
            description: All about dogs
        docs:
          - "octo/pets:docs"
        users:
          - id: sil
        icon: "pawprint.fill"
        ---

        # Pets

        A long text about the project.
        """
        let rendered = BoardStore.renderProjectReadme(
            name: "Pets and People", description: "", lanes: [], priorities: [],
            users: [User(id: "sil"), User(id: "mara")], types: ["fix"],
            epics: [Epic(id: "dogs", name: "Dogs and puppies", description: "All about dogs")])
        let patched = ReadmePatch.apply(rendered, to: original, keys: ["project", "lanes", "priorities", "users", "types", "epics"])
        XCTAssertEqual(patched, """
        ---
        config: board
        project: "Pets and People"
        repository: octo/pets
        epics:
          - id: dogs
            name: "Dogs and puppies"
            description: "All about dogs"
        docs:
          - "octo/pets:docs"
        users:
          - id: sil
          - id: mara
        icon: "pawprint.fill"
        types: [fix]
        ---

        # Pets

        A long text about the project.

        """)
        // A part that is left alone keeps its lines, also when the settings would drop it.
        let kept = ReadmePatch.apply(rendered, to: original, keys: ["users", "epics"], unchanged: ["epics"])
        XCTAssertTrue(kept.contains("    name: Dogs\n"))
        XCTAssertTrue(kept.contains("  - id: mara"))
    }

    // MARK: Products

    func testProductsAreReadFromTheReadmeAndWrittenBackInPlace() throws {
        let readme = "---\nconfig: project\nproject: Pets\nproducts:\n  - id: dogs\n    name: Dogs\n    prefix: dog\n  - Cats and Kittens\nicon: \"pawprint.fill\"\n---\n\nAbout.\n"
        let products = BoardStore.products(inReadme: readme)
        XCTAssertEqual(products, [BoardProduct(id: "dogs", name: "Dogs", prefix: "DOG"), BoardProduct(id: "cats-and-kittens", name: "Cats and Kittens")])
        XCTAssertNil(BoardProduct.cleanPrefix("12"))

        let patched = ReadmePatch.apply(BoardStore.renderProducts([products[1], BoardProduct(id: "birds", name: "Birds", prefix: "BIRD")]),
                                        to: readme, keys: ["products"])
        XCTAssertEqual(patched, "---\nconfig: project\nproject: Pets\nproducts:\n  - id: cats-and-kittens\n    name: \"Cats and Kittens\"\n  - id: birds\n    name: Birds\n    prefix: BIRD\nicon: \"pawprint.fill\"\n---\n\nAbout.\n")
        XCTAssertFalse(ReadmePatch.apply(BoardStore.renderProducts([]), to: readme, keys: ["products"]).contains("products:"))
    }

    func testATaskForAProductTakesItsPrefixAndField() async throws {
        try write("Pets/README.md", "---\nconfig: project\nproject: Pets\nproducts:\n  - id: dogs\n    name: Dogs\n    prefix: DOG\n  - id: cats\n    name: Cats\nlanes: []\n---\n")
        let board = try await board.describe()
        XCTAssertEqual((board["products"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["dogs", "cats"])

        let dog = try await self.board.createCard(title: "Teach sit", lane: nil, body: nil, fields: [("product", .string("dogs"))], createdBy: "claude")
        XCTAssertEqual(dog["id"] as? String, "DOG-001")
        XCTAssertTrue(try read("Pets/1. To do/DOG-001-teach-sit.md").contains("product: dogs"))

        // A product without a prefix keeps the board's own numbering.
        let cat = try await self.board.createCard(title: "Buy litter", lane: nil, body: nil, fields: [("product", .string("cats"))], createdBy: "claude")
        XCTAssertEqual(cat["id"] as? String, "PETS-002")

        do {
            _ = try await self.board.createCard(title: "x", lane: nil, body: nil, fields: [("product", .string("fish"))], createdBy: "claude")
            XCTFail("an unknown product was accepted")
        } catch let error as AgentBoardError { XCTAssertTrue(error.message.contains("products")) }
    }
}
