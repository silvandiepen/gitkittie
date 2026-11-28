import Foundation
import TasksAgentTools

/// Which board numbers which cards (GKM → tasks/GitKittie), learned from `get_board` on the
/// boards in the app's sidebar and kept in a small cache file, so `tasks show GKM-123` needs
/// no `--board` and asks the app for the boards only once.
public actor BoardIndex {
    let client: TasksClient
    let cacheFile: URL?
    private var map: [String: [String]]?

    public init(client: TasksClient, cacheFile: URL?) {
        self.client = client
        self.cacheFile = cacheFile
    }

    /// The default cache: the user's Caches folder (the tool's own container when sandboxed).
    public static func defaultCacheFile(environment: [String: String]) -> URL? {
        if let dir = environment["TASKS_CACHE_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("board-prefixes.json")
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("app.hakobs.gitkanban.tasks-cli", isDirectory: true)
            .appendingPathComponent("board-prefixes.json")
    }

    /// `GKM-123` → `GKM`; `GITKITTIE-021-some-title.md` → `GITKITTIE`.
    public static func prefix(of card: String) -> String? {
        guard let match = card.firstMatch(of: #/^([A-Za-z][A-Za-z0-9]*)-\d+/#) else { return nil }
        return String(match.output.1).uppercased()
    }

    /// The board for `card`. `fresh` forces a new look at the boards (the cached answer was wrong).
    public func board(for card: String, fresh: Bool = false) async throws -> (board: String?, cached: Bool) {
        guard let prefix = Self.prefix(of: card) else { return (nil, false) }
        if !fresh, let known = loadCache()[prefix], known.count == 1 { return (known[0], true) }
        let scanned = try await scan()
        guard let boards = scanned[prefix] else { return (nil, false) }
        if boards.count > 1 {
            throw CLIError.usage("Cards numbered \(prefix) are on more than one board (\(boards.joined(separator: ", "))). Say which with --board.")
        }
        return (boards[0], false)
    }

    private func loadCache() -> [String: [String]] {
        if let map { return map }
        guard let cacheFile, let data = try? Data(contentsOf: cacheFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else { return [:] }
        map = object
        return object
    }

    /// Ask every board in the sidebar for its id prefixes (its own and its products').
    private func scan() async throws -> [String: [String]] {
        let boards = try await sidebarBoards(client)
        var found: [String: [String]] = [:]
        try await withThrowingTaskGroup(of: (String, [String]).self) { group in
            var pending = boards.makeIterator()
            func next() {
                guard let board = pending.next() else { return }
                group.addTask { [client] in
                    // A board that cannot be read right now just teaches nothing.
                    guard let described = try? await client.callJSON("get_board", ["board": .string(board)]) as? [String: Any] else { return (board, []) }
                    var prefixes = [described["card_id_prefix"] as? String].compactMap { $0 }
                    prefixes += (described["products"] as? [[String: Any]] ?? []).compactMap { $0["card_id_prefix"] as? String }
                    return (board, prefixes)
                }
            }
            // A few at a time: each one costs the app a few requests to the board's source.
            for _ in 0..<4 { next() }
            for try await (board, prefixes) in group {
                for prefix in Set(prefixes.map { $0.uppercased() }) { found[prefix, default: []].append(board) }
                next()
            }
        }
        for key in found.keys { found[key]?.sort() }
        map = found
        if let cacheFile, let data = try? JSONSerialization.data(withJSONObject: found, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]) {
            try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
        }
        return found
    }
}

/// The boards in the app's sidebar: the ones a person works with. (Asking for a board that is
/// not in the sidebar puts it there, so a scan never touches those.)
func sidebarBoards(_ client: TasksClient) async throws -> [String] {
    let boards = try await client.callJSON("list_boards", [:]) as? [[String: Any]] ?? []
    return boards.filter { $0["in_app_sidebar"] as? Bool ?? false }.compactMap { $0["board"] as? String }
}

/// Runs a command line: parses it, makes the call, prints the answer.
public struct TasksCommand {
    public var environment: [String: String]
    public var input: InputSources
    public var output: (String) -> Void
    public var errorOutput: (String) -> Void
    public var renderer: Renderer
    public var client: TasksClient
    public var index: BoardIndex

    public init(environment: [String: String], input: InputSources, output: @escaping (String) -> Void, errorOutput: @escaping (String) -> Void,
                renderer: Renderer, client: TasksClient, index: BoardIndex) {
        self.environment = environment
        self.input = input
        self.output = output
        self.errorOutput = errorOutput
        self.renderer = renderer
        self.client = client
        self.index = index
    }

    /// Run `argv` (without the program name); returns the exit code.
    public func run(_ argv: [String]) async -> Int32 {
        var json = argv.contains("--json")
        do {
            let (invocation, wantsJSON) = try Commands.parse(argv, environment: environment, input: input)
            json = wantsJSON
            switch invocation {
            case .help(let text):
                output(text)
            case .version:
                output("tasks \(Commands.version)")
            case .tools(let name):
                output(try renderer.tools(name))
            case .guide(let board):
                var rules: AgentGuide.BoardRules?
                if let board {
                    let answer = try await client.callJSON("get_board_rules", ["board": .string(board)])
                    rules = AgentGuide.BoardRules(board: board, files: answer as? [String: Any] ?? [:])
                }
                let text = AgentGuide.text(rules: rules)
                output(json ? Renderer.pretty(text) : text)
            case .run(let plan):
                try await execute(plan, json: json)
            }
            return 0
        } catch let error as CLIError {
            report(error, json: json)
            return error.exitCode
        } catch {
            let failure = CLIError.unreachable(error.localizedDescription)
            report(failure, json: json)
            return failure.exitCode
        }
    }

    private func report(_ error: CLIError, json: Bool) {
        if json {
            let object: [String: Any] = ["error": error.message, "kind": error.kind, "exit_code": Int(error.exitCode)]
            errorOutput(Renderer.pretty(object))
        } else {
            errorOutput("tasks: " + error.message)
        }
    }

    func execute(_ plan: Plan, json: Bool) async throws {
        switch plan.board {
        case .given, .none:
            try await show(try await call(plan), plan: plan, json: json)
        case .fromCard(let card, let fallback):
            try await show(try await callOnCardBoard(plan, card: card, fallback: fallback), plan: plan, json: json)
        case .all:
            var merged: [[String: Any]] = []
            for board in try await sidebarBoards(client) {
                var arguments = plan.arguments
                arguments["board"] = .string(board)
                let answer = try await client.callJSON(plan.tool, arguments)
                for var entry in answer as? [[String: Any]] ?? [] {
                    entry["board"] = board
                    merged.append(entry)
                }
            }
            try await show(.json(merged), plan: plan, json: json)
        }
    }

    enum Answer {
        case json(Any)
        case text(String)
    }

    private func call(_ plan: Plan) async throws -> Answer {
        let result = try await client.call(plan.tool, plan.arguments)
        if result.isError { throw CLIError.tool(result.text) }
        if let value = try? JSONSerialization.jsonObject(with: Data(result.text.utf8), options: [.fragmentsAllowed]) { return .json(value) }
        return .text(result.text)
    }

    /// Find the card's board from its prefix and call there; when a remembered board turns
    /// out not to have the card, look at the boards again once.
    private func callOnCardBoard(_ plan: Plan, card: String, fallback: String?) async throws -> Answer {
        var plan = plan
        var (board, cached) = try await index.board(for: card)
        if board == nil { board = fallback }
        guard let board else {
            let prefix = BoardIndex.prefix(of: card).map { " numbers \($0) cards" } ?? " has this card"
            throw CLIError.tool("Could not tell which board\(prefix). Say which with --board (`tasks boards` lists them).")
        }
        plan.arguments["board"] = .string(board)
        let result = try await client.call(plan.tool, plan.arguments)
        if result.isError, cached, result.text.hasPrefix("No card") || result.text.hasPrefix("No board") {
            let (again, _) = try await index.board(for: card, fresh: true)
            if let again, again != board {
                plan.arguments["board"] = .string(again)
                return try await call(plan)
            }
        }
        if result.isError { throw CLIError.tool(result.text) }
        if let value = try? JSONSerialization.jsonObject(with: Data(result.text.utf8), options: [.fragmentsAllowed]) { return .json(value) }
        return .text(result.text)
    }

    private func show(_ answer: Answer, plan: Plan, json: Bool) async throws {
        switch answer {
        case .text(let text):
            output(text)
        case .json(let value):
            if case .reviewFile(let target?) = plan.view {
                let object = value as? [String: Any] ?? [:]
                guard let encoded = object["content_base64"] as? String, let data = Data(base64Encoded: encoded) else {
                    throw CLIError.tool("The app sent no file content.")
                }
                if target == "-" {
                    FileHandle.standardOutput.write(data)
                    return
                }
                do {
                    try data.write(to: URL(fileURLWithPath: (target as NSString).expandingTildeInPath))
                } catch {
                    throw CLIError.usage("Could not write \(target): \(error.localizedDescription) (If this copy of tasks runs sandboxed, use `-o -` and redirect standard output.)")
                }
                output(json ? Renderer.pretty(["request": object["request"] ?? "", "path": object["path"] ?? "", "bytes": data.count, "saved_to": target])
                            : "Saved \(target) (\(data.count) bytes).")
                return
            }
            if json || plan.view == .raw {
                if case .review(let id) = plan.view {
                    let match = (value as? [[String: Any]] ?? []).first { ($0["request"] as? String)?.lowercased() == id.lowercased() }
                    guard let match else { throw CLIError.tool("No review request \"\(id)\" on this board.") }
                    output(Renderer.pretty(match))
                } else {
                    output(Renderer.pretty(value))
                }
            } else {
                if case .review(let id) = plan.view,
                   !(value as? [[String: Any]] ?? []).contains(where: { ($0["request"] as? String)?.lowercased() == id.lowercased() }) {
                    throw CLIError.tool("No review request \"\(id)\" on this board.")
                }
                output(renderer.render(plan.view, value, plan: plan))
            }
        }
    }
}

extension TasksCommand {
    /// The command as the `tasks` executable runs it: real standard input, output, terminal
    /// width, connection file and app launcher.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> TasksCommand {
        let client = TasksClient(locator: .standard(environment: environment),
                                 launcher: environment["TASKS_NO_WAKE"].map { !$0.isEmpty && $0 != "0" } == true ? nil : WorkspaceLauncher())
        return TasksCommand(
            environment: environment, input: .process,
            output: { print($0) },
            errorOutput: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
            renderer: Renderer(width: terminalWidth(environment)),
            client: client,
            index: BoardIndex(client: client, cacheFile: BoardIndex.defaultCacheFile(environment: environment)))
    }

    static func terminalWidth(_ environment: [String: String]) -> Int? {
        guard isatty(STDOUT_FILENO) != 0 else { return nil }
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 { return Int(size.ws_col) }
        return environment["COLUMNS"].flatMap(Int.init)
    }
}
