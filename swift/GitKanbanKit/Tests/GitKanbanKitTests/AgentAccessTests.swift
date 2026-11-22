import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// Agent access end to end: a real MCP client conversation over HTTP against the app
/// model, on a real board in a temp folder laid out like the tasks repo.
@MainActor
final class AgentAccessTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var model: AppModel!
    private var port = 0
    private var token = ""

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gk-agent-\(UUID().uuidString)", isDirectory: true)
        try write("README.md", """
        ---
        config: board
        lanes:
          - id: todo
            name: To do
            folder: "1. To do"
            status: todo
          - id: in-progress
            name: In Progress
            folder: "2. In Progress"
            status: in-progress
          - id: done
            name: Done
            folder: "5. Done"
            status: done
            terminal: true
        priorities:
          - id: P1
          - id: P2
        types: [feature, chore]
        ---

        # Board contract

        Cards follow TASK_TEMPLATE.md.
        """)
        try write("TASK_TEMPLATE.md", """
        ---
        id: PROJECT-000
        title: Replace with a concise outcome
        project: project-folder-name
        status: todo
        priority: P2
        type: chore
        assignee: null
        created_by: agent-or-person
        created_at: 1970-01-01T00:00:00Z
        updated_at: 1970-01-01T00:00:00Z
        picked_up_by: null
        claim_expires_at: null
        blocked: false
        commits: []
        tags: []
        ---

        # Replace with task title

        ## Context

        Explain why this task exists.

        ## Activity log
        """)
        try write("Pets/README.md", "---\nconfig: project\nproject: Pets\nlanes: []\n---\n")
        try write("Pets/1. To do/PETS-007-feed-the-cat.md", """
        ---
        id: PETS-007
        title: Feed the cat
        project: Pets
        status: todo
        priority: P2
        picked_up_by: null
        commits:
          - abc
          - def
        agent_only: keep
        ---

        # Feed the cat

        ## Context

        The cat is hungry.

        ## Activity log

        - 2026-11-01T10:00:00Z — `sil` created the card.
        """)
        try write("Pets/2. In Progress/PETS-003-walk-the-dog.md", "---\nid: PETS-003\ntitle: Walk: the dog\nstatus: in-progress\npicked_up_by: herma\nclaim_expires_at: 2099-01-01T00:00:00Z\n---\n\n# Walk the dog\n")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Pets/5. Done"), withIntermediateDirectories: true)

        suite = "gk-agent-\(UUID().uuidString)"
        model = AppModel(appGroup: suite, keychainService: "gk-agent-tests-\(UUID().uuidString)", migratesLegacyStorage: false)
        model.addedRepos = [AddedRepo(namespace: "folder", name: "tasks", branch: "", isPrivate: true,
                                      boards: [SelectedBoard(folder: "Pets", name: "Pets")],
                                      kind: .localFolder(path: root.path, bookmark: nil))]
        model.agentPort = 0
        token = "test-token-0123456789abcdef0123456789abcdef"
        let dispatcher = MCPDispatcher(serverName: "tasks", serverVersion: "1", instructions: AgentTools.instructions, tools: AgentTools.all) { [model] name, arguments in
            try await model!.runAgentTool(name, arguments: arguments)
        }
        let server = MCPHTTPServer(token: token, dispatcher: dispatcher)
        port = Int(try await server.start(port: 0))
        model.agentServer = server
    }

    override func tearDown() async throws {
        await model.agentServer?.stop()
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((text + "\n").utf8).write(to: url)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func post(_ body: [String: Any], token: String? = nil, headers: [String: String] = [:]) async throws -> (status: Int, json: [String: Any]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token = token ?? Optional(self.token) { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
    }

    /// Call a tool; returns its text and whether it reported an error.
    private func call(_ name: String, _ arguments: [String: Any]) async throws -> (text: String, isError: Bool) {
        let (status, json) = try await post(["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
        XCTAssertEqual(status, 200)
        let result = try XCTUnwrap(json["result"] as? [String: Any], "\(json)")
        let content = try XCTUnwrap((result["content"] as? [[String: Any]])?.first)
        return (content["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    func testHandshakeListsToolsAndRefusesStrangers() async throws {
        let (status, hello) = try await post(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                              "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]])
        XCTAssertEqual(status, 200)
        let result = try XCTUnwrap(hello["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "tasks")

        // A notification is accepted without an answer.
        let (notified, _) = try await post(["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertEqual(notified, 202)

        let (_, listed) = try await post(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }),
                       ["list_boards", "create_board", "get_board", "get_board_rules", "list_cards", "get_card", "create_card", "update_card", "claim_card", "attach_file",
                        "list_reviews", "create_review", "handle_review_item", "close_review", "wait_for_reviews", "list_docs", "get_doc", "search_docs", "write_doc", "delete_doc"])
        for tool in tools {
            // Every schema must have parsed as a JSON Schema object, not fallen back.
            XCTAssertNotNil((tool["inputSchema"] as? [String: Any])?["properties"], "\(tool["name"] ?? "")")
        }

        let (noToken, _) = try await post(["jsonrpc": "2.0", "id": 3, "method": "tools/list"], token: "wrong")
        XCTAssertEqual(noToken, 401)
        let (fromBrowser, _) = try await post(["jsonrpc": "2.0", "id": 4, "method": "tools/list"], headers: ["Origin": "https://evil.example"])
        XCTAssertEqual(fromBrowser, 403)
        let (_, unknown) = try await post(["jsonrpc": "2.0", "id": 5, "method": "resources/list"])
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    func testReadingBoardsAndCards() async throws {
        let boards = try await call("list_boards", [:])
        XCTAssertTrue(boards.text.contains("\"board\" : \"tasks/Pets\""), boards.text)

        let board = try object(try await call("get_board", ["board": "Pets"]).text)
        XCTAssertEqual(board["card_id_prefix"] as? String, "PETS")
        XCTAssertEqual((board["lanes"] as? [[String: Any]])?.map { $0["status"] as? String }, ["todo", "in-progress", "done"])

        let rules = try object(try await call("get_board_rules", ["board": "tasks/Pets"]).text)
        XCTAssertTrue((rules["contract"] as? String)?.contains("Board contract") == true)
        XCTAssertTrue((rules["template"] as? String)?.contains("PROJECT-000") == true)

        let progress = try await call("list_cards", ["board": "Pets", "lane": "in-progress"])
        // The unquoted colon makes that card's frontmatter invalid YAML; it must still read.
        XCTAssertTrue(progress.text.contains("Walk: the dog"), progress.text)
        XCTAssertTrue(progress.text.contains("\"picked_up_by\" : \"herma\""), progress.text)
        XCTAssertFalse(progress.text.contains("PETS-007"))

        let card = try object(try await call("get_card", ["board": "Pets", "card": "PETS-007"]).text)
        XCTAssertEqual(card["lane"] as? String, "To do")
        XCTAssertTrue((card["text"] as? String)?.contains("The cat is hungry.") == true)

        let missing = try await call("get_card", ["board": "Pets", "card": "PETS-999"])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("No card"))
        let noBoard = try await call("get_card", ["board": "Nope", "card": "PETS-007"])
        XCTAssertTrue(noBoard.isError)
    }

    func testCreateClaimUpdateMoveAndAttach() async throws {
        let created = try object(try await call("create_card", [
            "board": "Pets", "title": "Brush the rabbit: weekly", "agent": "hermio",
            "fields": ["priority": "P1", "type": "feature", "tags": ["grooming", "rabbit"]],
        ]).text)
        XCTAssertEqual(created["id"] as? String, "PETS-008")
        XCTAssertEqual(created["file"] as? String, "PETS-008-brush-the-rabbit-weekly.md")
        let fresh = try read("Pets/1. To do/PETS-008-brush-the-rabbit-weekly.md")
        let parsed = BoardStore.parseCard(text: fresh, fileName: "x.md", fieldSource: nil)
        XCTAssertEqual(parsed.fields.title, "Brush the rabbit: weekly")   // valid YAML: the colon is quoted
        XCTAssertEqual(parsed.fields.priority, "P1")
        XCTAssertEqual(parsed.fields.project, "Pets")
        XCTAssertTrue(fresh.contains("tags: [grooming, rabbit]"), fresh)
        XCTAssertTrue(fresh.contains("created_by: hermio"))
        XCTAssertTrue(fresh.contains("# Brush the rabbit: weekly"))
        XCTAssertTrue(fresh.contains("## Context"))           // the template's sections
        XCTAssertTrue(fresh.contains("`hermio` created the card."))
        XCTAssertFalse(fresh.contains("PROJECT-000"))

        // Someone else's live claim is not taken over.
        let taken = try await call("claim_card", ["board": "Pets", "card": "PETS-003", "agent": "hermio"])
        XCTAssertTrue(taken.isError)
        XCTAssertTrue(taken.text.contains("already claimed by herma"), taken.text)

        let claimed = try object(try await call("claim_card", ["board": "Pets", "card": "PETS-007", "agent": "hermio", "working_branch": "feat/cat"]).text)
        XCTAssertEqual(claimed["lane"] as? String, "In Progress")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Pets/1. To do/PETS-007-feed-the-cat.md").path))
        var card = try read("Pets/2. In Progress/PETS-007-feed-the-cat.md")
        XCTAssertTrue(card.contains("status: in-progress"))
        XCTAssertTrue(card.contains("picked_up_by: hermio"))
        XCTAssertTrue(card.contains("working_branch: feat/cat"))
        XCTAssertTrue(card.contains("agent_only: keep"))
        XCTAssertTrue(card.contains("`hermio` claimed the card."))
        XCTAssertTrue(card.contains("`sil` created the card."))

        let updated = try await call("update_card", [
            "board": "Pets", "card": "PETS-007", "agent": "hermio", "lane": "done",
            "fields": ["commits": ["123abc"], "blocked": true, "picked_up_by": NSNull(), "completed_by": "hermio"],
            "activity": "fed the cat and closed the card.",
        ])
        XCTAssertFalse(updated.isError, updated.text)
        card = try read("Pets/5. Done/PETS-007-feed-the-cat.md")
        XCTAssertTrue(card.contains("status: done"))
        // Quoted, so a commit id made of digits and an "e" can never be read as a number.
        XCTAssertTrue(card.contains("commits: [\"123abc\"]"), card)
        XCTAssertFalse(card.contains("  - abc"))               // the old block list went with its key
        XCTAssertTrue(card.contains("blocked: true"))
        XCTAssertTrue(card.contains("picked_up_by: null"))
        XCTAssertTrue(card.contains("agent_only: keep"))
        XCTAssertTrue(card.contains("The cat is hungry."))
        XCTAssertTrue(card.hasSuffix("`hermio` fed the cat and closed the card.\n"), card)
        XCTAssertEqual(BoardStore.parseCard(text: card, fileName: "x.md", fieldSource: nil).fields.status, "done")

        let attached = try await call("attach_file", ["board": "Pets", "card": "PETS-007", "file_name": "after fix.png",
                                                      "content_base64": Data("png-bytes".utf8).base64EncodedString()])
        XCTAssertFalse(attached.isError, attached.text)
        XCTAssertEqual(try read("Pets/attachments/PETS-007/after-fix.png"), "png-bytes")

        let nothing = try await call("update_card", ["board": "Pets", "card": "PETS-008", "agent": "hermio"])
        XCTAssertTrue(nothing.isError)
        let renamed = try await call("update_card", ["board": "Pets", "card": "PETS-008", "agent": "hermio", "fields": ["id": "PETS-1"]])
        XCTAssertTrue(renamed.isError)
    }

    func testBoardsOutsideTheSidebarAreReachableAndNewBoardsCanBeMade() async throws {
        // A board that exists in the repository but was never added in the app.
        try write("Fish/README.md", "---\nconfig: project\nproject: Fish\nlanes: []\n---\n")
        try write("Fish/1. To do/FISH-001-feed.md", "---\nid: FISH-001\ntitle: Feed the fish\nstatus: todo\n---\n")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)

        let listed = try await call("list_boards", [:])
        XCTAssertTrue(listed.text.contains("\"board\" : \"tasks/Fish\""), listed.text)
        XCTAssertFalse(listed.text.contains(".hidden"))
        XCTAssertEqual(model.addedRepos[0].boards.map(\.folder), ["Pets"])

        let cards = try await call("list_cards", ["board": "tasks/Fish"])
        XCTAssertTrue(cards.text.contains("FISH-001"), cards.text)
        XCTAssertEqual(model.addedRepos[0].boards.map(\.folder).sorted(), ["Fish", "Pets"])   // now in the sidebar

        let made = try object(try await call("create_board", ["name": "Birds", "description": "Everything about the aviary.", "agent": "hermio"]).text)
        XCTAssertEqual(made["board"] as? String, "tasks/Birds")
        XCTAssertEqual(made["lanes"] as? [String], ["To do", "In Progress", "Done"])
        let readme = try read("Birds/README.md")
        let config = try BoardStore.parseProjectConfig(yaml: try XCTUnwrap(BoardMarkdown.splitFrontmatter(readme).0))
        XCTAssertEqual(config.project, "Birds")
        XCTAssertEqual(config.lanes, [])
        XCTAssertTrue(readme.contains("Everything about the aviary."))
        XCTAssertEqual(model.addedRepos[0].boards.map(\.folder).sorted(), ["Birds", "Fish", "Pets"])

        // The new board works like any other: its first card gets the board's own prefix.
        let first = try object(try await call("create_card", ["board": "tasks/Birds", "title": "Buy seed", "agent": "hermio"]).text)
        XCTAssertEqual(first["id"] as? String, "BIRDS-001")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Birds/1. To do/BIRDS-001-buy-seed.md").path))

        // In a git repository each lane gets a placeholder file, since git keeps no empty folders.
        let memory = InMemoryBoardSource(files: ["README.md": try read("README.md")])
        let viaGit = try await AgentBoardFactory.create(source: memory, parent: "", name: "Cats", description: nil, agent: "hermio", lanePlaceholders: true)
        XCTAssertEqual(viaGit.folder, "Cats")
        let cats = try await memory.list("Cats").map(\.name).sorted()
        XCTAssertEqual(cats, ["1. To do", "2. In Progress", "5. Done", "README.md"])
        let keep = try await memory.list("Cats/1. To do").map(\.name)
        XCTAssertEqual(keep, [".gitkeep"])

        let again = try await call("create_board", ["name": "birds", "agent": "hermio"])
        XCTAssertTrue(again.isError)
        XCTAssertTrue(again.text.contains("already exists"), again.text)
        let bad = try await call("create_board", ["name": "a/b", "agent": "hermio"])
        XCTAssertTrue(bad.isError)
    }

    func testRulesAtBothLevelsReachTheAgentAndTheBoardsVocabularyIsEnforced() async throws {
        try write("AGENTS.md", "Repository rule: one card per outcome.")
        try write("Pets/RULES.md", "Board rule: every card names the animal.")
        try write("Pets/README.md", "---\nconfig: project\nproject: Pets\nlanes: []\ntypes: [grooming]\n---\n\n# Pets\n\nPets board notes.")
        let rules = try object(try await call("get_board_rules", ["board": "Pets"]).text)
        XCTAssertTrue((rules["contract"] as? String)?.contains("Board contract") == true)
        XCTAssertEqual((rules["repository_AGENTS.md"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), "Repository rule: one card per outcome.")
        XCTAssertEqual((rules["board_RULES.md"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), "Board rule: every card names the animal.")
        XCTAssertTrue((rules["board_readme"] as? String)?.contains("Pets board notes.") == true)
        XCTAssertNotNil(rules["template"])

        // The board's own types extend the repository's.
        let board = try object(try await call("get_board", ["board": "Pets"]).text)
        XCTAssertEqual(Set(board["types"] as? [String] ?? []), ["feature", "chore", "grooming"])

        let wrongPriority = try await call("create_card", ["board": "Pets", "title": "Trim claws", "agent": "hermio", "fields": ["priority": "urgent"]])
        XCTAssertTrue(wrongPriority.isError)
        XCTAssertTrue(wrongPriority.text.contains("Use one of: P1, P2"), wrongPriority.text)
        let wrongType = try await call("update_card", ["board": "Pets", "card": "PETS-007", "agent": "hermio", "fields": ["type": "epic-quest"]])
        XCTAssertTrue(wrongType.isError)
        let statusOnly = try await call("update_card", ["board": "Pets", "card": "PETS-007", "agent": "hermio", "fields": ["status": "done"]])
        XCTAssertTrue(statusOnly.isError)
        XCTAssertTrue(statusOnly.text.contains("Move the card with"), statusOnly.text)
        // Nothing was written by the refused calls.
        XCTAssertTrue(try read("Pets/1. To do/PETS-007-feed-the-cat.md").contains("status: todo"))

        let ok = try await call("create_card", ["board": "Pets", "title": "Trim claws", "agent": "hermio", "fields": ["priority": "P1", "type": "grooming"]])
        XCTAssertFalse(ok.isError, ok.text)
    }

    func testAnAgentsChangeShowsOnTheOpenBoard() async throws {
        await model.openBoard(model.addedRepos[0], folder: "Pets")
        XCTAssertEqual(model.board?.columns.first?.cards.count, 1)
        _ = try await call("create_card", ["board": "Pets", "title": "Clean the cage", "agent": "hermio"])
        XCTAssertEqual(model.board?.columns.first?.cards.map(\.fields.id).sorted(), ["PETS-007", "PETS-008"])
        model.closeRepo()
    }
}
