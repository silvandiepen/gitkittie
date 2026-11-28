import GitKittieKit
import TasksAgentTools
import TasksCLIKit
import XCTest
@testable import GitKanbanKit

/// The `tasks` command line: how each command turns into a tool call.
final class TasksCLIParsingTests: XCTestCase {
    private let env = ["TASKS_AGENT": "claude"]

    private func plan(_ argv: [String], env: [String: String]? = nil, files: [String: String] = [:], stdin: String = "") throws -> Plan {
        let input = InputSources(stdin: { Data(stdin.utf8) }, file: { path in
            guard let text = files[path] else { throw CocoaError(.fileReadNoSuchFile) }
            return Data(text.utf8)
        })
        guard case .run(let plan) = try Commands.parse(argv, environment: env ?? self.env, input: input).0 else {
            throw CLIError.usage("not a call")
        }
        return plan
    }

    private func usageError(_ argv: [String], env: [String: String]? = nil, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try Commands.parse(argv, environment: env ?? self.env, input: InputSources(stdin: { Data() }, file: { _ in throw CocoaError(.fileReadNoSuchFile) }))
            XCTFail("\(argv) parsed", file: file, line: line)
            return ""
        } catch let error as CLIError {
            XCTAssertEqual(error.exitCode, 2, file: file, line: line)
            return error.message
        } catch {
            XCTFail("\(error)", file: file, line: line)
            return ""
        }
    }

    func testUpdateWithOptionsFindsTheBoardFromTheCard() throws {
        let plan = try plan(["update", "GKM-123", "--description", "New body", "--priority", "P1", "--tags", "mail, sync",
                             "--set", "blocked=true", "--set", "commits=[\"123\"]", "--set", "pull_request=91", "--set", "reviewer=null",
                             "--activity", "Rewrote the body."])
        XCTAssertEqual(plan.tool, "update_card")
        XCTAssertEqual(plan.board, .fromCard("GKM-123", fallback: nil))
        XCTAssertEqual(plan.view, .updated)
        XCTAssertEqual(plan.arguments, [
            "card": .string("GKM-123"), "agent": .string("claude"), "body": .string("New body"), "activity": .string("Rewrote the body."),
            "fields": .object(["priority": .string("P1"), "tags": .array([.string("mail"), .string("sync")]), "blocked": .bool(true),
                               "commits": .array([.string("123")]), "pull_request": .string("91"), "reviewer": .null]),
        ])
    }

    /// As Sil wrote it: `tasks update GKM-123 '{"description":"…"}'`.
    func testUpdateWithAJSONObject() throws {
        let plan = try plan(["update", "GKM-123", #"{"description": "Body", "priority": "P2", "lane": "review", "comment": "Done.", "fields": {"blocked": false}}"#])
        XCTAssertEqual(plan.arguments, [
            "card": .string("GKM-123"), "agent": .string("claude"), "body": .string("Body"), "lane": .string("in-review"),
            "activity": .string("Done."), "fields": .object(["priority": .string("P2"), "blocked": .bool(false)]),
        ])
        let fromStdin = try self.plan(["update", "GKM-123", "-"], stdin: #"{"description": "From a pipe"}"#)
        XCTAssertEqual(fromStdin.arguments["body"], .string("From a pipe"))
        XCTAssertTrue(usageError(["update", "GKM-123", "not json"]).contains("not a JSON object"))
        XCTAssertTrue(usageError(["update", "GKM-123"]).contains("nothing to change"))
    }

    func testCreateReadsTheBodyFileAndNeedsABoard() throws {
        let plan = try plan(["create", "--board", "GitKittie", "--title", "Fix the badge", "-p", "P2", "--body-file", "notes.md", "--lane", "todo"],
                            files: ["notes.md": "## Context\n\nIt is wrong."])
        XCTAssertEqual(plan.tool, "create_card")
        XCTAssertEqual(plan.board, .given)
        XCTAssertEqual(plan.arguments, [
            "board": .string("GitKittie"), "title": .string("Fix the badge"), "agent": .string("claude"),
            "body": .string("## Context\n\nIt is wrong."), "lane": .string("todo"), "fields": .object(["priority": .string("P2")]),
        ])
        let positional = try self.plan(["create", "Quick one", #"{"type": "chore"}"#], env: ["TASKS_AGENT": "claude", "TASKS_BOARD": "Pets"])
        XCTAssertEqual(positional.arguments["title"], .string("Quick one"))
        XCTAssertEqual(positional.arguments["board"], .string("Pets"))
        XCTAssertEqual(positional.arguments["fields"], .object(["type": .string("chore")]))
        XCTAssertTrue(usageError(["create", "--title", "x"]).contains("say which board"))
        XCTAssertTrue(usageError(["create", "--board", "Pets"]).contains("give a title"))
        XCTAssertTrue(usageError(["create", "--board", "Pets", "--title", "x", "--body-file", "missing.md"]).contains("--body-file - <"))
    }

    func testListMoveClaimCommentAndTheGlobalOptions() throws {
        let list = try plan(["--board", "GitKittie", "list", "--lane", "in-progress", "--mine", "-q", "sync", "--limit", "5"])
        XCTAssertEqual(list.tool, "list_cards")
        XCTAssertEqual(list.arguments, ["board": .string("GitKittie"), "lane": .string("in-progress"), "assignee": .string("claude"),
                                        "query": .string("sync"), "limit": .number(5)])
        XCTAssertEqual(try plan(["ls", "--all"]).board, .all)
        XCTAssertEqual(try plan(["list"], env: ["TASKS_BOARD": "Pets"]).arguments, ["board": .string("Pets")])

        let move = try plan(["move", "GKM-1", "review", "-m", "Opened the PR."])
        XCTAssertEqual(move.tool, "update_card")
        XCTAssertEqual(move.arguments, ["card": .string("GKM-1"), "lane": .string("in-review"), "agent": .string("claude"), "activity": .string("Opened the PR.")])

        let claim = try plan(["claim", "GKM-1", "--hours", "2", "--branch", "feat/x", "--agent", "codex"])
        XCTAssertEqual(claim.arguments, ["card": .string("GKM-1"), "agent": .string("codex"), "hours": .number(2), "working_branch": .string("feat/x")])

        let comment = try plan(["comment", "GKM-1", "fixed", "the", "badge."])
        XCTAssertEqual(comment.arguments["activity"], .string("fixed the badge."))

        // An explicit board wins over the card's prefix; TASKS_BOARD is only the fallback.
        XCTAssertEqual(try plan(["show", "GKM-1", "-b", "Mail"]).arguments["board"], .string("Mail"))
        XCTAssertEqual(try plan(["show", "GKM-1"], env: ["TASKS_BOARD": "Pets"]).board, .fromCard("GKM-1", fallback: "Pets"))

        let (invocation, json) = try Commands.parse(["--json", "show", "GKM-1"], environment: [:])
        XCTAssertTrue(json)
        guard case .run(let show) = invocation else { return XCTFail() }
        XCTAssertEqual(show.arguments, ["card": .string("GKM-1")])
    }

    func testReviewsDocsRawAndBoardCommands() throws {
        XCTAssertEqual(try plan(["reviews", "--card", "GKM-8", "--state", "all"]).board, .fromCard("GKM-8", fallback: nil))
        let handle = try plan(["review", "handle", "icons", "a", "--shipped-to", "assets/a.png", "-b", "Pets"])
        XCTAssertEqual(handle.tool, "handle_review_item")
        XCTAssertEqual(handle.arguments, ["board": .string("Pets"), "request": .string("icons"), "item": .string("a"), "shipped_to": .string("assets/a.png")])
        XCTAssertEqual(try plan(["review", "show", "icons", "-b", "Pets"]).view, .review("icons"))
        XCTAssertEqual(try plan(["review", "wait", "--timeout", "30", "-b", "Pets"]).arguments["timeout_seconds"], .number(30))
        XCTAssertEqual(try plan(["docs", "search", "sync", "badge", "-b", "Pets"]).arguments["query"], .string("sync badge"))
        XCTAssertEqual(try plan(["rules", "GitKittie"], env: [:]).arguments, ["board": .string("GitKittie")])

        let raw = try plan(["raw", "get_card", #"{"card": "GKM-1"}"#])
        XCTAssertEqual(raw.board, .fromCard("GKM-1", fallback: nil))
        XCTAssertEqual(raw.view, .raw)
        let rawUpdate = try plan(["raw", "update_card", #"{"board": "Pets", "card": "PETS-1", "activity": "x"}"#])
        XCTAssertEqual(rawUpdate.arguments["agent"], .string("claude"))   // filled in from TASKS_AGENT
        XCTAssertEqual(try plan(["raw", "list_boards"]).arguments, [:])
        XCTAssertTrue(usageError(["raw", "drop_tables"]).contains("no tool"))
    }

    func testMistakesAreUsageErrors() {
        XCTAssertTrue(usageError(["update", "GKM-1", "--priority", "P1"], env: [:]).contains("TASKS_AGENT"))
        XCTAssertTrue(usageError(["list", "--colour", "red", "-b", "x"]).contains("unknown option --colour"))
        XCTAssertTrue(usageError(["list"]).contains("say which board"))
        XCTAssertTrue(usageError(["show"]).contains("missing <card>"))
        XCTAssertTrue(usageError(["frobnicate"]).contains("Unknown command"))
        XCTAssertTrue(usageError(["claim", "GKM-1", "--hours", "soon"]).contains("--hours"))
        XCTAssertTrue(usageError(["list", "-b"]).contains("needs a value"))
    }

    /// The commands call only tools the server offers, with every argument the tool requires.
    /// (The tool list is the server's own, shared through TasksAgentTools.)
    func testEveryCommandCallsARealToolWithItsRequiredArguments() throws {
        let lines: [[String]] = [
            ["boards"], ["board", "Pets"], ["rules", "Pets"], ["list", "-b", "Pets"], ["show", "P-1"],
            ["create", "-b", "Pets", "-t", "T"], ["update", "P-1", "-p", "P1"], ["move", "P-1", "done"], ["claim", "P-1"],
            ["comment", "P-1", "x"], ["reviews", "-b", "Pets"], ["review", "show", "r", "-b", "Pets"],
            ["review", "handle", "r", "i", "-b", "Pets"], ["review", "close", "r", "-b", "Pets"], ["review", "wait", "-b", "Pets"],
            ["review", "create", "-b", "Pets", "--title", "T"], ["review", "check", "-b", "Pets", "--title", "T", "--url", "https://x.example", "--item", "Loads"],
            ["review", "file", "r", "results/a.png", "-b", "Pets"],
            ["docs", "-b", "Pets"], ["docs", "show", "README.md", "-b", "Pets"], ["docs", "search", "q", "-b", "Pets"],
            ["create-board", "Birds"],
        ]
        var used: Set<String> = []
        for line in lines {
            let plan = try plan(line)
            let tool = try XCTUnwrap(AgentTools.all.first { $0.name == plan.tool }, "\(line) calls \(plan.tool), which the server does not offer")
            used.insert(tool.name)
            let schema = ToolSchema(tool)
            for key in schema.required where key != "board" || plan.board == .given {
                XCTAssertNotNil(plan.arguments[key], "\(line): \(tool.name) requires \(key)")
            }
            for key in plan.arguments.keys { XCTAssertTrue(schema.properties.contains(key), "\(line): \(tool.name) has no argument \(key)") }
        }
        // Everything but writing docs has its own command (attach_file is `attach`, read from a file
        // or standard input); those go through `raw`. (`tasks guide` prints the guide itself,
        // offline: the same text get_agent_guide returns.)
        XCTAssertEqual(Set(AgentTools.all.map(\.name)).subtracting(used), ["attach_file", "write_doc", "delete_doc", "get_agent_guide"])
    }

    func testTheGuideCommand() throws {
        XCTAssertEqual(try Commands.parse(["guide"]).0, .guide(board: nil))
        XCTAssertEqual(try Commands.parse(["guide", "--board", "Pets"]).0, .guide(board: "Pets"))
        XCTAssertEqual(try Commands.parse(["guide", "-b", "Pets", "--json"]).json, true)
        // TASKS_BOARD alone does not make the guide ask the app for anything.
        XCTAssertEqual(try Commands.parse(["guide"], environment: ["TASKS_BOARD": "Pets"]).0, .guide(board: nil))
        XCTAssertTrue(usageError(["guide", "Pets"]).contains("unexpected"))
        guard case .help(let overview) = try Commands.parse(["--help"]).0 else { return XCTFail() }
        XCTAssertTrue(overview.contains("run `tasks guide` first"))
    }

    /// The guide's reference is generated from the command table and the tool list, so it names
    /// every command (with its usage and options), every tool (with its arguments), every exit
    /// code and every environment variable, and has no placeholder left.
    func testTheGuideCoversEveryCommandToolAndExitCode() throws {
        let guide = AgentGuide.text()
        XCTAssertFalse(guide.contains("{{"), "a placeholder was not filled in")
        XCTAssertFalse(guide.contains("Sil"), "the guide is about the person using the app, not one named person")
        for spec in CommandTable.all {
            XCTAssertTrue(guide.contains("### `tasks \(spec.name)`"), "the guide has no section for \(spec.name)")
            for usage in spec.usage { XCTAssertTrue(guide.contains(usage), "the guide lacks the usage \(usage)") }
            for option in spec.options { XCTAssertTrue(guide.contains("`\(option.label)`: \(option.help)"), "\(spec.name): the guide lacks \(option.label)") }
            XCTAssertFalse(spec.examples.isEmpty, "\(spec.name) has no example")
            for example in spec.examples { XCTAssertTrue(guide.contains(example), "the guide lacks the example \(example)") }
            if !["tools", "help"].contains(spec.name) { XCTAssertNotNil(spec.returns, "\(spec.name) does not say what --json prints") }
            for tool in spec.tools { XCTAssertNotNil(AgentTools.all.first { $0.name == tool }, "\(spec.name) names \(tool), which the server does not offer") }
        }
        for option in CommandTable.global { XCTAssertTrue(guide.contains("`\(option.label)`"), "the guide lacks the global option \(option.label)") }
        for tool in AgentTools.all {
            XCTAssertTrue(guide.contains("### `\(tool.name)`\n\n\(tool.description)"), "the guide lacks the tool \(tool.name)")
            for property in ToolSchema(tool).properties {
                XCTAssertTrue(guide.contains("- `\(property)`"), "the guide lacks \(tool.name)'s argument \(property)")
            }
        }
        for status in ExitStatus.allCases { XCTAssertTrue(guide.contains("| \(status.rawValue) | "), "the guide lacks exit code \(status.rawValue)") }
        for variable in CommandTable.environment { XCTAssertTrue(guide.contains("`\(variable.name)`")) }
        // The prose comes first, the reference after it.
        XCTAssertTrue(guide.hasPrefix("# Tasks: the agent guide\n"))
        let order = try ["## 3. The start of every session", "## 5. The card lifecycle", "## 6. Reviews", "## 9. Command reference",
                     "## 10. Exit codes", "## 11. Tool reference"].map { try XCTUnwrap(guide.range(of: $0)?.lowerBound, $0) }
        XCTAssertEqual(order, order.sorted())
    }

    /// Every command line in the guide (the command table's examples and the prose's `sh` blocks)
    /// is one the CLI accepts.
    func testEveryCommandLineInTheGuideParses() throws {
        var lines = CommandTable.all.flatMap(\.examples)
        var inShell = false
        for line in AgentGuide.prose.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inShell = line.trimmingCharacters(in: .whitespaces) == "```sh"; continue }
            if inShell, line.trimmingCharacters(in: .whitespaces).hasPrefix("tasks ") { lines.append(line.trimmingCharacters(in: .whitespaces)) }
        }
        XCTAssertGreaterThan(lines.count, CommandTable.all.count + 3)
        let input = InputSources(stdin: { Data("{}".utf8) }, file: { _ in Data("body".utf8) })
        for line in lines {
            let words = try shellWords(line)
            XCTAssertEqual(words.first, "tasks", line)
            XCTAssertNoThrow(try Commands.parse(Array(words.dropFirst()), environment: env, input: input), line)
        }
    }

    /// Split a command line as a shell would: quotes, backslash escapes in double quotes, and
    /// nothing from the first unquoted redirection on.
    private func shellWords(_ line: String) throws -> [String] {
        var words: [String] = []
        var word = ""
        var started = false
        var quote: Character?
        var characters = Array(line)[...]
        while let character = characters.popFirst() {
            if let open = quote {
                if character == open { quote = nil } else if open == "\"", character == "\\", let next = characters.popFirst() { word.append(next) } else { word.append(character) }
                continue
            }
            switch character {
            case "'", "\"": quote = character; started = true
            case " ":
                if started { words.append(word); word = ""; started = false }
            case "<" where !started:
                return words
            default: word.append(character); started = true
            }
        }
        if quote != nil { throw CLIError.usage("unclosed quote in \(line)") }
        if started { words.append(word) }
        return words
    }

    func testHelp() throws {
        guard case .help(let overview) = try Commands.parse(["--help"]).0 else { return XCTFail() }
        XCTAssertTrue(overview.contains("Exit codes"))
        guard case .help(let update) = try Commands.parse(["update", "--help"]).0 else { return XCTFail() }
        XCTAssertTrue(update.contains("--description"))
        XCTAssertTrue(update.contains(try XCTUnwrap(AgentTools.all.first { $0.name == "update_card" }).description))
        guard case .help(let viaHelp) = try Commands.parse(["help", "move"]).0 else { return XCTFail() }
        XCTAssertTrue(viaHelp.contains("tasks move <card> <lane>"))
        XCTAssertEqual(try Commands.parse(["--version"]).0, .version)
    }

    func testCardIDPrefixes() {
        XCTAssertEqual(BoardIndex.prefix(of: "GKM-123"), "GKM")
        XCTAssertEqual(BoardIndex.prefix(of: "gitkittie-021-some-title.md"), "GITKITTIE")
        XCTAssertNil(BoardIndex.prefix(of: "README.md"))
    }

    func testTheInstallLinksTheToolAndReplacesOnlyItsOwnLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tcli-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = root.appendingPathComponent("Tasks.app/Contents/Helpers/tasks")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        let folder = root.appendingPathComponent(".local/bin", isDirectory: true)

        let link = try CommandLineTool.install(tool, into: folder)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), tool.path)
        XCTAssertEqual(CommandLineTool.installedTarget(in: folder)?.path, tool.standardizedFileURL.path)
        // Installing again (another copy of the app) replaces the link.
        let other = root.appendingPathComponent("Other.app/Contents/Helpers/tasks")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: other)
        try CommandLineTool.install(other, into: folder)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), other.path)
        // Someone else's `tasks` is never overwritten.
        let elsewhere = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: elsewhere.appendingPathComponent("tasks"))
        XCTAssertThrowsError(try CommandLineTool.install(tool, into: elsewhere)) { error in
            XCTAssertEqual(error as? CommandLineTool.InstallError, .occupied(elsewhere.appendingPathComponent("tasks").path))
        }

        XCTAssertEqual(CommandLineTool.pathLine(for: CommandLineTool.suggestedFolder), "export PATH=\"$HOME/.local/bin:$PATH\"")
        XCTAssertNil(CommandLineTool.pathLine(for: URL(fileURLWithPath: "/opt/homebrew/bin")))
    }
}

/// The `tasks` command end to end: the real client, over HTTP, against the app model's own
/// agent server on a random port with a test token, on a board in a temp folder.
@MainActor
final class TasksCLIIntegrationTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var model: AppModel!
    private var server: MCPHTTPServer!
    private var port = 0
    private let token = "tcli-test-token-0123456789abcdef0123456789"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tcli-\(UUID().uuidString)", isDirectory: true)
        try write("board/README.md", """
        ---
        config: board
        lanes:
          - {id: todo, name: To do, folder: "1. To do", status: todo}
          - {id: in-progress, name: In Progress, folder: "2. In Progress", status: in-progress}
          - {id: in-review, name: In Review, folder: "3. In Review", status: in-review}
          - {id: done, name: Done, folder: "5. Done", status: done, terminal: true}
        priorities:
          - id: P1
          - id: P2
        types: [feature, chore]
        ---

        # Board contract
        """)
        try write("board/TASK_TEMPLATE.md", "---\nid: PROJECT-000\ntitle: T\nstatus: todo\npriority: P2\npicked_up_by: null\n---\n\n# T\n\n## Context\n\n## Activity log\n")
        try write("board/Pets/README.md", "---\nconfig: project\nproject: Pets\nlanes: []\n---\n")
        try write("board/Pets/1. To do/PETS-007-feed-the-cat.md", "---\nid: PETS-007\ntitle: Feed the cat\nstatus: todo\npriority: P2\npicked_up_by: null\n---\n\n# Feed the cat\n\nThe cat is hungry.\n")
        try write("board/Pets/2. In Progress/PETS-003-walk-the-dog.md", "---\nid: PETS-003\ntitle: Walk the dog\nstatus: in-progress\npicked_up_by: herma\nclaim_expires_at: 2099-01-01T00:00:00Z\n---\n\n# Walk the dog\n")
        for lane in ["3. In Review", "5. Done"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("board/Pets/\(lane)"), withIntermediateDirectories: true)
        }
        suite = "tcli-\(UUID().uuidString)"
        model = AppModel.testing(suite: suite, keychainService: "tcli-tests-\(UUID().uuidString)")
        model.addedRepos = [AddedRepo(namespace: "folder", name: "tasks", branch: "", isPrivate: true,
                                      boards: [SelectedBoard(folder: "Pets", name: "Pets")],
                                      kind: .localFolder(path: root.appendingPathComponent("board").path, bookmark: nil))]
        server = try await startServer()
    }

    override func tearDown() async throws {
        await server?.stop()
        try? FileManager.default.removeItem(at: root)
        AppModel.removeTestStorage(suite)
    }

    /// The app model's agent server, as the app starts it, on a port the system picks.
    private func startServer() async throws -> MCPHTTPServer {
        let dispatcher = MCPDispatcher(serverName: "tasks", serverVersion: "1", instructions: AgentTools.instructions, tools: AgentTools.all) { [model] name, arguments in
            try await model!.runAgentTool(name, arguments: arguments)
        }
        let server = MCPHTTPServer(token: token, dispatcher: dispatcher)
        port = Int(try await server.start(port: 0))
        try writeConnection(port: port, token: token)
        return server
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("board/Pets/\(path)"), encoding: .utf8)
    }

    private var connectionFile: URL { root.appendingPathComponent("AgentAccess/connection.json") }

    private func writeConnection(port: Int, token: String) throws {
        try FileManager.default.createDirectory(at: connectionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["port": port, "token": token, "app": root.appendingPathComponent("No.app").path]).write(to: connectionFile)
    }

    private struct Run { var code: Int32; var out: String; var err: String }

    /// Run `tasks` with this argv against the test server, as the executable would.
    private func tasks(_ argv: [String], agent: String? = "hermio", connection: URL? = nil, launcher: AppLauncher? = nil) async -> Run {
        let out = Buffer(), err = Buffer()
        var environment = ["TASKS_CACHE_DIR": root.appendingPathComponent("cache").path]
        if let agent { environment["TASKS_AGENT"] = agent }
        let client = TasksClient(locator: ConnectionLocator(candidates: [connection ?? connectionFile]), launcher: launcher, wakeTimeout: 10)
        let command = TasksCommand(environment: environment, input: InputSources(stdin: { Data() }, file: { _ in throw CocoaError(.fileReadNoPermission) }),
                                   output: { out.text += $0 + "\n" }, errorOutput: { err.text += $0 + "\n" },
                                   renderer: Renderer(width: nil), client: client,
                                   index: BoardIndex(client: client, cacheFile: root.appendingPathComponent("cache/board-prefixes.json")))
        let code = await command.run(argv)
        return Run(code: code, out: out.text, err: err.text)
    }

    func testReadingAndChangingCardsThroughTheCommand() async throws {
        let boards = await tasks(["boards"])
        XCTAssertEqual(boards.code, 0, boards.err)
        XCTAssertTrue(boards.out.contains("tasks/Pets"), boards.out)
        XCTAssertTrue(boards.out.hasPrefix("BOARD"), boards.out)

        let list = await tasks(["list", "--board", "Pets"])
        XCTAssertEqual(list.code, 0, list.err)
        XCTAssertTrue(list.out.contains("PETS-007  To do"), list.out)
        XCTAssertTrue(list.out.contains("herma"), list.out)
        XCTAssertTrue(list.out.contains("2 cards"), list.out)

        // No --board: the card's prefix leads to the board, and that is remembered.
        let show = await tasks(["show", "PETS-007"])
        XCTAssertEqual(show.code, 0, show.err)
        XCTAssertTrue(show.out.hasPrefix("PETS-007  Feed the cat"), show.out)
        XCTAssertTrue(show.out.contains("The cat is hungry."), show.out)
        let cache = try String(contentsOf: root.appendingPathComponent("cache/board-prefixes.json"), encoding: .utf8)
        XCTAssertTrue(cache.contains("\"PETS\""), cache)

        let created = await tasks(["create", "--board", "Pets", "--title", "Brush the rabbit", "--priority", "P1", "--tags", "fur"])
        XCTAssertEqual(created.code, 0, created.err)
        XCTAssertTrue(created.out.hasPrefix("Created PETS-008 in To do"), created.out)
        let fresh = try read("1. To do/PETS-008-brush-the-rabbit.md")
        XCTAssertTrue(fresh.contains("priority: P1"), fresh)
        XCTAssertTrue(fresh.contains("created_by: hermio"), fresh)

        // As Sil wrote it, with a JSON object.
        let updated = await tasks(["update", "PETS-008", ##"{"description": "# Brush the rabbit\n\nWeekly.", "priority": "P2", "activity": "Wrote it down."}"##])
        XCTAssertEqual(updated.code, 0, updated.err)
        XCTAssertTrue(updated.out.hasPrefix("Updated PETS-008"), updated.out)
        var card = try read("1. To do/PETS-008-brush-the-rabbit.md")
        XCTAssertTrue(card.contains("priority: P2"), card)
        XCTAssertTrue(card.contains("Weekly."), card)
        XCTAssertTrue(card.contains("`hermio` Wrote it down."), card)

        let claimed = await tasks(["claim", "PETS-008", "--branch", "feat/rabbit"])
        XCTAssertEqual(claimed.code, 0, claimed.err)
        XCTAssertTrue(claimed.out.hasPrefix("Claimed PETS-008 (In Progress)"), claimed.out)

        let moved = await tasks(["move", "PETS-008", "review", "--activity", "Ready."])
        XCTAssertEqual(moved.code, 0, moved.err)
        XCTAssertEqual(moved.out, "Moved PETS-008 to In Review.\n")
        card = try read("3. In Review/PETS-008-brush-the-rabbit.md")
        XCTAssertTrue(card.contains("status: in-review"), card)
        XCTAssertTrue(card.contains("working_branch: feat/rabbit"), card)

        let commented = await tasks(["comment", "PETS-008", "Looked", "again."])
        XCTAssertEqual(commented.code, 0, commented.err)
        XCTAssertTrue(try read("3. In Review/PETS-008-brush-the-rabbit.md").contains("`hermio` Looked again."))

        // --json: the app's answer, for agents.
        let json = await tasks(["list", "--board", "Pets", "--lane", "in-review", "--json"])
        XCTAssertEqual(json.code, 0, json.err)
        let cards = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [[String: Any]])
        XCTAssertEqual(cards.map { $0["id"] as? String }, ["PETS-008"])

        let raw = await tasks(["raw", "get_board", #"{"board": "Pets"}"#])
        XCTAssertEqual(raw.code, 0, raw.err)
        XCTAssertTrue(raw.out.contains("\"card_id_prefix\" : \"PETS\""), raw.out)
    }

    /// `tasks guide` works without the app; `--board` appends the board's rules from the app; the
    /// server's get_agent_guide returns the very same text, with and without a board.
    func testTheGuideOfflineWithTheBoardsRulesAndOverMCP() async throws {
        let offline = await tasks(["guide"], connection: root.appendingPathComponent("none/connection.json"))
        XCTAssertEqual(offline.code, 0, offline.err)
        XCTAssertEqual(offline.out, AgentGuide.text() + "\n")

        let json = await tasks(["guide", "--json"], connection: root.appendingPathComponent("none/connection.json"))
        XCTAssertEqual(json.code, 0, json.err)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(json.out.utf8), options: .fragmentsAllowed) as? String, AgentGuide.text())

        let withRules = await tasks(["guide", "--board", "Pets"])
        XCTAssertEqual(withRules.code, 0, withRules.err)
        XCTAssertTrue(withRules.out.hasPrefix(AgentGuide.text().trimmingCharacters(in: .newlines) + "\n\n## This board's rules: `Pets`"), String(withRules.out.suffix(2_000)))
        XCTAssertTrue(withRules.out.contains("### The repository's contract (its README.md)"), withRules.out)
        XCTAssertTrue(withRules.out.contains("# Board contract"), "the board's contract is in it")
        XCTAssertTrue(withRules.out.contains("### The card template (TASK_TEMPLATE.md)"))
        XCTAssertTrue(withRules.out.contains("config: project\nproject: Pets"), "the board's own README is in it")

        // The tool, over MCP through the real server.
        let viaTool = await tasks(["raw", "get_agent_guide"])
        XCTAssertEqual(viaTool.code, 0, viaTool.err)
        XCTAssertEqual(viaTool.out, offline.out)
        let viaToolWithRules = await tasks(["raw", "get_agent_guide", #"{"board": "Pets"}"#])
        XCTAssertEqual(viaToolWithRules.code, 0, viaToolWithRules.err)
        XCTAssertEqual(viaToolWithRules.out, withRules.out)

        let unknown = await tasks(["guide", "--board", "Nope"])
        XCTAssertEqual(unknown.code, 1)
        XCTAssertTrue(unknown.err.contains("No board"), unknown.err)
        XCTAssertTrue(unknown.out.isEmpty, "nothing is printed when the board's rules cannot be read")
    }

    /// The owner claiming again is the heartbeat: the lease moves, the claim keeps its start.
    func testClaimingYourOwnCardAgainRenewsTheLease() async throws {
        let first = await tasks(["claim", "PETS-007", "--hours", "1"])
        XCTAssertEqual(first.code, 0, first.err)
        let path = "2. In Progress/PETS-007-feed-the-cat.md"
        let claimed = try read(path)
        let started = try XCTUnwrap(claimed.firstMatch(of: #/picked_up_at: (\S+)/#)?.output.1)
        // Pretend the claim is older, as it would be at a heartbeat.
        let older = claimed.replacingOccurrences(of: "picked_up_at: \(started)", with: "picked_up_at: 2026-01-01T00:00:00Z")
        try Data(older.utf8).write(to: root.appendingPathComponent("board/Pets/\(path)"))

        let renewed = await tasks(["claim", "PETS-007", "--hours", "8"])
        XCTAssertEqual(renewed.code, 0, renewed.err)
        let card = try read(path)
        XCTAssertTrue(card.contains("picked_up_at: 2026-01-01T00:00:00Z"), card)
        XCTAssertTrue(card.contains("`hermio` renewed the claim until"), card)
        let expires = try XCTUnwrap(card.firstMatch(of: #/claim_expires_at: (\S+)/#)?.output.1)
        let lease = try XCTUnwrap(ISO8601DateFormatter().date(from: String(expires))).timeIntervalSinceNow
        XCTAssertGreaterThan(lease, 7 * 3600)

        // Someone else still cannot take it.
        let other = await tasks(["claim", "PETS-007"], agent: "codex")
        XCTAssertEqual(other.code, 1)
        XCTAssertTrue(other.err.contains("already claimed by hermio"), other.err)
    }

    func testRefusalsAndMistakesExitWithTheirCodes() async throws {
        let missing = await tasks(["show", "PETS-999"])
        XCTAssertEqual(missing.code, 1)
        XCTAssertTrue(missing.err.contains("No card \"PETS-999\""), missing.err)

        let unknownBoard = await tasks(["list", "--board", "Nope"])
        XCTAssertEqual(unknownBoard.code, 1)
        XCTAssertTrue(unknownBoard.err.contains("No board"), unknownBoard.err)

        let someoneElses = await tasks(["claim", "PETS-003"])
        XCTAssertEqual(someoneElses.code, 1)
        XCTAssertTrue(someoneElses.err.contains("already claimed by herma"), someoneElses.err)

        let noPrefix = await tasks(["show", "feed-the-cat"])
        XCTAssertEqual(noPrefix.code, 1)
        XCTAssertTrue(noPrefix.err.contains("--board"), noPrefix.err)

        let jsonError = await tasks(["show", "PETS-999", "--board", "Pets", "--json"])
        XCTAssertEqual(jsonError.code, 1)
        let error = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(jsonError.err.utf8)) as? [String: Any], jsonError.err)
        XCTAssertEqual(error["kind"] as? String, "refused")
        XCTAssertEqual(error["exit_code"] as? Int, 1)

        let noAgent = await tasks(["comment", "PETS-007", "hi"], agent: nil)
        XCTAssertEqual(noAgent.code, 2)

        // Nothing was written by any of these.
        XCTAssertTrue(try read("1. To do/PETS-007-feed-the-cat.md").hasSuffix("The cat is hungry.\n"))
    }

    func testAWrongTokenAClosedAppAndNoSetUp() async throws {
        let wrong = root.appendingPathComponent("wrong/connection.json")
        try FileManager.default.createDirectory(at: wrong.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["port": port, "token": "not-the-token"]).write(to: wrong)
        let refused = await tasks(["boards"], connection: wrong)
        XCTAssertEqual(refused.code, 4, refused.err)
        XCTAssertTrue(refused.err.contains("token"), refused.err)

        let nothing = await tasks(["boards"], connection: root.appendingPathComponent("none/connection.json"))
        XCTAssertEqual(nothing.code, 5)
        XCTAssertTrue(nothing.err.contains("Agent Access"), nothing.err)

        // The app is closed and may not be opened (TASKS_NO_WAKE).
        await server.stop()
        let closed = await tasks(["boards"])
        XCTAssertEqual(closed.code, 3)
        XCTAssertTrue(closed.err.contains("not running"), closed.err)
    }

    /// Nothing listens: the command opens the app (here: starts the server, which writes a new
    /// port into the connection file as the app does) and retries.
    func testItWakesTheAppWhenNothingListens() async throws {
        await server.stop()
        let launcher = StartingLauncher { @MainActor [self] in self.server = try await self.startServer() }
        let run = await tasks(["list", "--board", "Pets"], launcher: launcher)
        XCTAssertEqual(run.code, 0, run.err)
        XCTAssertTrue(run.out.contains("PETS-007"), run.out)
        let opened = await launcher.opened
        XCTAssertEqual(opened, [root.appendingPathComponent("No.app").path])
    }
}

private final class Buffer { var text = "" }

/// Stands in for Launch Services: "opening the app" starts the in-process server.
private actor StartingLauncher: AppLauncher {
    let start: @Sendable () async throws -> Void
    var opened: [String?] = []
    init(start: @escaping @Sendable () async throws -> Void) { self.start = start }

    func open(appAt path: String?) async -> Bool {
        opened.append(path)
        do { try await start(); return true } catch { return false }
    }
}
