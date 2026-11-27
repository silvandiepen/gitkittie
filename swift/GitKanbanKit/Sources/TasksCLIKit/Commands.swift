import Foundation
import TasksAgentTools

/// One call to the app, worked out from a command line.
public struct Plan: Equatable, Sendable {
    /// How the call's board is decided.
    public enum BoardChoice: Equatable, Sendable {
        /// `arguments["board"]` is set (`--board`, `TASKS_BOARD`, or a board argument).
        case given
        /// From the card's id prefix (GKM-123 → the board whose cards use GKM); `fallback`
        /// (`TASKS_BOARD`) when no board uses that prefix.
        case fromCard(String, fallback: String?)
        /// The call is made on every board in the app's sidebar (`--all`).
        case all
        /// The tool takes no board.
        case none
    }

    /// How the answer is shown to a person.
    public enum View: Equatable, Sendable {
        case boards, board, rules, cards, card, created, updated, moved, claimed, commented, attached
        case reviews, review(String), handled, closed, docs, doc, docHits, boardCreated, raw
    }

    public var tool: String
    public var arguments: [String: JSONValue]
    public var board: BoardChoice
    public var view: View
}

/// What a command line asks for.
public enum Invocation: Equatable, Sendable {
    case help(String)
    case version
    /// The app's tools, from the list the server shares (offline).
    case tools(String?)
    /// The agent guide (offline); with a board, that board's rules are fetched and appended.
    case guide(board: String?)
    case run(Plan)
}

/// What the command line can read besides its arguments.
public struct InputSources {
    public var stdin: () -> Data
    public var file: (String) throws -> Data

    public init(stdin: @escaping () -> Data, file: @escaping (String) throws -> Data) {
        self.stdin = stdin
        self.file = file
    }

    /// The process's standard input and files relative to the working directory.
    public static var process: InputSources {
        InputSources(stdin: { FileHandle.standardInput.readDataToEndOfFile() }, file: { path in
            try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        })
    }
}

public enum Commands {
    public static let version = "1.0.0"

    static var global: [OptionSpec] { CommandTable.global }
    static var all: [CommandSpec] { CommandTable.all }

    static func spec(_ word: String) -> CommandSpec? { CommandTable.spec(word) }

    // MARK: Parsing

    /// Turn a command line into what to do. `environment` gives TASKS_BOARD and TASKS_AGENT.
    public static func parse(_ argv: [String], environment: [String: String] = [:], input: InputSources = .process) throws -> (Invocation, json: Bool) {
        // The command is the first word that is not a global option or its value.
        if argv == ["--version"] || argv == ["-v"] { return (.version, false) }
        var index = 0
        var commandIndex: Int?
        while index < argv.count {
            let word = argv[index]
            if word == "--" { break }
            if word.hasPrefix("-"), word != "-" {
                let name = word.hasPrefix("--") ? String(word.dropFirst(2).prefix { $0 != "=" }) : nil
                let short = word.hasPrefix("--") ? nil : word.dropFirst().first
                if let option = global.first(where: { ($0.name == name) || (short != nil && $0.short == short) }), option.takesValue, !word.contains("=") {
                    index += 1
                }
                index += 1
                continue
            }
            commandIndex = index
            break
        }
        guard let commandIndex else {
            let parsed = try ParsedArguments.parse(argv, specs: global, command: "tasks")
            return (.help(overview()), parsed.has("json"))
        }
        let word = argv[commandIndex]
        if word == "version" { return (.version, false) }
        guard let spec = spec(word) else {
            throw CLIError.usage("Unknown command \"\(word)\". See `tasks --help`.")
        }
        var rest = argv
        rest.remove(at: commandIndex)
        let args = try ParsedArguments.parse(rest, specs: global + spec.options, command: spec.name)
        let json = args.has("json")
        if args.has("help") { return (.help(help(for: spec)), json) }
        let context = Context(spec: spec, args: args, environment: environment, input: input)
        return (try context.invocation(), json)
    }

    // MARK: Help

    public static func overview() -> String {
        let width = all.map(\.name.count).max() ?? 10
        let commands = all.map { "  \($0.name.padding(toLength: width + 2, withPad: " ", startingAt: 0))\($0.summary)" }.joined(separator: "\n")
        let envWidth = (CommandTable.environment.map(\.name.count).max() ?? 10) + 2
        let environment = CommandTable.environment.map { "  \($0.name.padding(toLength: envWidth, withPad: " ", startingAt: 0))\($0.help)" }.joined(separator: "\n")
        let exitCodes = ExitStatus.allCases.map { "  \($0.rawValue)  \($0.meaning)" }.joined(separator: "\n")
        return """
        tasks — work with your boards in the Tasks app (GitKittie Tasks) from a terminal.

        Usage: tasks <command> [arguments] [--json] [--board <board>] [--agent <handle>]

        Agents: run `tasks guide` first. It is the whole manual: how to work on the boards,
        every command and tool, and what to do when something fails.

        Commands:
        \(commands)

        Examples:
          tasks guide --board GitKittie
          tasks boards
          tasks list --board GitKittie --lane in-progress
          tasks show GKM-123
          tasks create --board GitKittie --title "Fix the sync badge" --priority P2 --body-file notes.md
          tasks update GKM-123 --description "New body" --tags mail,sync --set blocked=true
          tasks update GKM-123 '{"description": "New body", "priority": "P1"}'
          tasks move GKM-123 review --activity "Opened PR #91."
          tasks claim GKM-123 --branch feat/sync-badge

        Talks to the running Tasks app through Agent Access (the same server and token as the
        `tasks` MCP server) and opens Tasks in the background when it is closed. Every change is
        committed by the app at once: a command that succeeds has landed.

        Environment:
        \(environment)

        Exit codes:
        \(exitCodes)

        `tasks <command> --help` shows a command's options.
        """
    }

    static func help(for spec: CommandSpec) -> String {
        var out = spec.summary + "\n\nUsage:\n" + spec.usage.map { "  " + $0 }.joined(separator: "\n")
        if !spec.aliases.isEmpty { out += "\n\nAlso: " + spec.aliases.joined(separator: ", ") }
        let options = spec.options + global
        let labels = options.map { ($0.short == nil ? "    " : "") + $0.label }
        let width = (labels.map(\.count).max() ?? 0) + 2
        out += "\n\nOptions:\n" + zip(labels, options).map { "  \($0.0.padding(toLength: width, withPad: " ", startingAt: 0))\($0.1.help)" }.joined(separator: "\n")
        if let notes = spec.notes { out += "\n\n" + notes }
        if !spec.examples.isEmpty { out += "\n\nExamples:\n" + spec.examples.map { "  " + $0 }.joined(separator: "\n") }
        let tools = spec.tools.compactMap { name in AgentTools.all.first { $0.name == name } }
        if !tools.isEmpty {
            out += "\n\nCalls the app's " + (tools.count == 1 ? "tool" : "tools") + ":\n"
            out += tools.map { "  \($0.name): \($0.description)" }.joined(separator: "\n")
        }
        return out
    }
}

/// Builds the call for one command.
private struct Context {
    let spec: CommandSpec
    let args: ParsedArguments
    let environment: [String: String]
    let input: InputSources

    var positionals: [String] { args.positionals }

    func env(_ key: String) -> String? {
        environment[key].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    var givenBoard: String? { args.value("board") ?? env("TASKS_BOARD") }

    func agent() throws -> String {
        if let agent = args.value("agent") ?? env("TASKS_AGENT") { return agent }
        throw CLIError.usage("Say who you are: --agent <handle>, or set TASKS_AGENT (e.g. export TASKS_AGENT=claude). It is recorded on the card.")
    }

    func positional(_ index: Int, _ name: String) throws -> String {
        guard positionals.count > index else {
            throw CLIError.usage("\(spec.name): missing <\(name)>. Usage: \(spec.usage[0])")
        }
        return positionals[index]
    }

    func noMorePositionals(than count: Int) throws {
        if positionals.count > count {
            throw CLIError.usage("\(spec.name): unexpected \"\(positionals[count])\". Usage: \(spec.usage[0])")
        }
    }

    /// A call on one board: `--board` / TASKS_BOARD, or the board from `card`'s prefix.
    func plan(_ tool: String, _ arguments: [String: JSONValue], card: String? = nil, view: Plan.View) throws -> Plan {
        var arguments = arguments
        if let board = args.value("board") {
            arguments["board"] = .string(board)
            return Plan(tool: tool, arguments: arguments, board: .given, view: view)
        }
        if let card { return Plan(tool: tool, arguments: arguments, board: .fromCard(card, fallback: env("TASKS_BOARD")), view: view) }
        if args.has("all") { return Plan(tool: tool, arguments: arguments, board: .all, view: view) }
        if let board = env("TASKS_BOARD") {
            arguments["board"] = .string(board)
            return Plan(tool: tool, arguments: arguments, board: .given, view: view)
        }
        throw CLIError.usage("\(spec.name): say which board: --board <board> (or set TASKS_BOARD). `tasks boards` lists them.")
    }

    func invocation() throws -> Invocation {
        switch spec.name {
        case "help":
            if let word = positionals.first {
                guard let target = Commands.spec(word) else { throw CLIError.usage("Unknown command \"\(word)\". See `tasks --help`.") }
                return .help(Commands.help(for: target))
            }
            return .help(Commands.overview())
        case "tools":
            try noMorePositionals(than: 1)
            return .tools(positionals.first)
        case "guide":
            // Only an explicit --board: TASKS_BOARD alone does not make the guide fetch anything.
            try noMorePositionals(than: 0)
            return .guide(board: args.value("board"))
        case "boards":
            try noMorePositionals(than: 0)
            return .run(Plan(tool: "list_boards", arguments: [:], board: .none, view: .boards))
        case "board", "rules":
            try noMorePositionals(than: 1)
            var arguments: [String: JSONValue] = [:]
            if let board = positionals.first ?? givenBoard { arguments["board"] = .string(board) } else {
                throw CLIError.usage("\(spec.name): say which board: tasks \(spec.name) <board> (or --board / TASKS_BOARD). `tasks boards` lists them.")
            }
            return .run(Plan(tool: spec.name == "board" ? "get_board" : "get_board_rules", arguments: arguments, board: .given,
                             view: spec.name == "board" ? .board : .rules))
        case "list":
            try noMorePositionals(than: 0)
            var arguments: [String: JSONValue] = [:]
            if let lane = args.value("lane") { arguments["lane"] = .string(lane) }
            if let query = args.value("query") { arguments["query"] = .string(query) }
            if args.has("mine") { arguments["assignee"] = .string(try agent()) }
            if let assignee = args.value("assignee") { arguments["assignee"] = .string(assignee) }
            if let limit = args.value("limit") {
                guard let number = Int(limit), number > 0 else { throw CLIError.usage("list: --limit is a whole number above 0.") }
                arguments["limit"] = .number(Double(number))
            }
            return .run(try plan("list_cards", arguments, view: .cards))
        case "show":
            let card = try positional(0, "card")
            try noMorePositionals(than: 1)
            return .run(try plan("get_card", ["card": .string(card)], card: card, view: .card))
        case "create":
            return .run(try create())
        case "update":
            return .run(try update())
        case "move":
            let card = try positional(0, "card")
            let lane = try positional(1, "lane")
            try noMorePositionals(than: 2)
            var arguments: [String: JSONValue] = ["card": .string(card), "lane": .string(Self.lane(lane)), "agent": .string(try agent())]
            if let activity = args.value("activity") { arguments["activity"] = .string(activity) }
            return .run(try plan("update_card", arguments, card: card, view: .moved))
        case "claim":
            let card = try positional(0, "card")
            try noMorePositionals(than: 1)
            var arguments: [String: JSONValue] = ["card": .string(card), "agent": .string(try agent())]
            if let hours = args.value("hours") {
                guard let number = Double(hours), number > 0 else { throw CLIError.usage("claim: --hours is a number above 0.") }
                arguments["hours"] = .number(number)
            }
            if let branch = args.value("branch") { arguments["working_branch"] = .string(branch) }
            return .run(try plan("claim_card", arguments, card: card, view: .claimed))
        case "comment":
            let card = try positional(0, "card")
            let text = positionals.dropFirst().joined(separator: " ")
            let activity = text == "-" ? String(decoding: input.stdin(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : text
            guard !activity.isEmpty else { throw CLIError.usage("comment: say what to log. Usage: \(spec.usage[0])") }
            return .run(try plan("update_card", ["card": .string(card), "activity": .string(activity), "agent": .string(try agent())], card: card, view: .commented))
        case "attach":
            let card = try positional(0, "card")
            let path = try positional(1, "file")
            try noMorePositionals(than: 2)
            let data = try read(path)
            let name = args.value("name") ?? (path == "-" ? "attachment" : (path as NSString).lastPathComponent)
            return .run(try plan("attach_file", ["card": .string(card), "file_name": .string(name), "content_base64": .string(data.base64EncodedString())],
                                 card: card, view: .attached))
        case "reviews":
            try noMorePositionals(than: 0)
            return .run(try reviews(state: args.value("state")))
        case "review":
            return .run(try review())
        case "docs":
            return .run(try docs())
        case "create-board":
            let name = try positional(0, "name")
            try noMorePositionals(than: 1)
            var arguments: [String: JSONValue] = ["name": .string(name), "agent": .string(try agent())]
            if let description = args.value("description") { arguments["description"] = .string(description) }
            if let repository = args.value("repository") { arguments["repository"] = .string(repository) }
            return .run(Plan(tool: "create_board", arguments: arguments, board: .none, view: .boardCreated))
        case "raw":
            return .run(try raw())
        default:
            throw CLIError.usage("Unknown command \"\(spec.name)\".")
        }
    }

    // MARK: Cards

    /// `review` is the lane people say; the lane's status is `in-review`.
    static func lane(_ word: String) -> String {
        switch word.lowercased() {
        case "review": "in-review"
        case "progress", "doing", "wip": "in-progress"
        case "todo", "to-do": "todo"
        default: word
        }
    }

    func read(_ path: String) throws -> Data {
        if path == "-" { return input.stdin() }
        do { return try input.file(path) } catch {
            throw CLIError.usage("Could not read \(path): \(error.localizedDescription) (If this copy of tasks runs sandboxed, pass the file on standard input instead: `--body-file - < \(path)`.)")
        }
    }

    /// `key=value` as a frontmatter value: null, true, false and `[…]` lists are typed;
    /// everything else (numbers too: a commit id of digits must stay text) is a string.
    static func fieldValue(_ raw: String) throws -> JSONValue {
        switch raw {
        case "null": return .null
        case "true": return .bool(true)
        case "false": return .bool(false)
        default:
            if raw.hasPrefix("[") {
                guard case .array(let items)? = try? JSONValue.parse(raw) else {
                    throw CLIError.usage("\(raw) is not a JSON list. Write lists as [\"a\", \"b\"].")
                }
                return .array(items)
            }
            return .string(raw)
        }
    }

    /// The fields, body and lane the field options give.
    func fieldArguments(allowTitle: Bool) throws -> (fields: [String: JSONValue], body: String?, lane: String?) {
        var fields: [String: JSONValue] = [:]
        if allowTitle, let title = args.value("title") { fields["title"] = .string(title) }
        for key in ["priority", "type", "assignee", "epic"] {
            if let value = args.value(key) { fields[key] = value == "null" ? .null : .string(value) }
        }
        if let tags = args.value("tags") {
            fields["tags"] = .array(tags.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 != .string("") })
        }
        for assignment in args.values["set"] ?? [] {
            guard let equals = assignment.firstIndex(of: "="), equals != assignment.startIndex else {
                throw CLIError.usage("--set takes key=value, e.g. --set blocked=true.")
            }
            fields[String(assignment[..<equals])] = try Self.fieldValue(String(assignment[assignment.index(after: equals)...]))
        }
        var body = args.value("description") ?? args.value("body")
        if let file = args.value("body-file") {
            guard body == nil else { throw CLIError.usage("Give the body once: --description, --body or --body-file.") }
            body = String(decoding: try read(file), as: UTF8.self)
        }
        return (fields, body, args.value("lane").map(Self.lane))
    }

    /// A JSON object given as Sil writes it: `{"description": "…", "priority": "P1"}`.
    func jsonArgument(_ text: String) throws -> [String: JSONValue] {
        let source = text == "-" ? String(decoding: input.stdin(), as: UTF8.self) : text
        guard case .object(let object)? = try? JSONValue.parse(source) else {
            throw CLIError.usage("\(spec.name): that is not a JSON object. Example: tasks \(spec.name) GKM-123 '{\"description\": \"…\"}'")
        }
        return object
    }

    /// Merge a JSON object into a call: the tool's own keys stay, description/body become the
    /// body, comment the activity, every other key a frontmatter field.
    func merge(_ object: [String: JSONValue], into arguments: inout [String: JSONValue], ownKeys: Set<String>) throws {
        var fields = arguments["fields"]?.objectValue ?? [:]
        for (key, value) in object {
            switch key {
            case "description", "body":
                guard case .string = value else { throw CLIError.usage("\"\(key)\" must be text.") }
                arguments["body"] = value
            case "comment":
                arguments["activity"] = value
            case "move":
                arguments["lane"] = value
            case "fields":
                guard case .object(let more) = value else { throw CLIError.usage("\"fields\" must be an object.") }
                fields.merge(more) { $1 }
            case "lane":
                arguments["lane"] = value.string.map { .string(Self.lane($0)) } ?? value
            case _ where ownKeys.contains(key):
                arguments[key] = value
            default:
                fields[key] = value
            }
        }
        if !fields.isEmpty { arguments["fields"] = .object(fields) }
    }

    func create() throws -> Plan {
        var arguments: [String: JSONValue] = ["agent": .string(try agent())]
        let (fields, body, lane) = try fieldArguments(allowTitle: false)
        if !fields.isEmpty { arguments["fields"] = .object(fields) }
        if let body { arguments["body"] = .string(body) }
        if let lane { arguments["lane"] = .string(lane) }
        if let title = args.value("title") { arguments["title"] = .string(title) }
        for word in positionals {
            if word.hasPrefix("{") || word == "-" {
                try merge(try jsonArgument(word), into: &arguments, ownKeys: ["title", "agent"])
            } else if arguments["title"] == nil {
                arguments["title"] = .string(word)
            } else {
                throw CLIError.usage("create: unexpected \"\(word)\". Quote the title: tasks create --title \"…\".")
            }
        }
        guard arguments["title"] != nil else { throw CLIError.usage("create: give a title: --title \"…\".") }
        return try plan("create_card", arguments, view: .created)
    }

    func update() throws -> Plan {
        let card = try positional(0, "card")
        var arguments: [String: JSONValue] = ["card": .string(card), "agent": .string(try agent())]
        let (fields, body, lane) = try fieldArguments(allowTitle: true)
        if !fields.isEmpty { arguments["fields"] = .object(fields) }
        if let body { arguments["body"] = .string(body) }
        if let lane { arguments["lane"] = .string(lane) }
        if let activity = args.value("activity") { arguments["activity"] = .string(activity) }
        for word in positionals.dropFirst() {
            try merge(try jsonArgument(word), into: &arguments, ownKeys: ["activity", "agent"])
        }
        guard arguments.keys.contains(where: { ["fields", "body", "lane", "activity"].contains($0) }) else {
            throw CLIError.usage("update: nothing to change. Give a field option, --description, --lane, --activity or a JSON object. See `tasks update --help`.")
        }
        return try plan("update_card", arguments, card: card, view: .updated)
    }

    // MARK: Reviews and docs

    func reviews(state: String?) throws -> Plan {
        var arguments: [String: JSONValue] = [:]
        if let state { arguments["state"] = .string(state) }
        let card = args.value("card")
        if let card { arguments["card"] = .string(card) }
        return try plan("list_reviews", arguments, card: card, view: .reviews)
    }

    func review() throws -> Plan {
        let sub = positionals.first ?? "list"
        switch sub {
        case "list":
            return try reviews(state: args.value("state"))
        case "show":
            let id = try positional(1, "request")
            try noMorePositionals(than: 2)
            return try plan("list_reviews", ["state": .string("all")], view: .review(id))
        case "handle":
            let request = try positional(1, "request")
            let item = try positional(2, "item")
            try noMorePositionals(than: 3)
            var arguments: [String: JSONValue] = ["request": .string(request), "item": .string(item)]
            if let shipped = args.value("shipped-to") { arguments["shipped_to"] = .string(shipped) }
            if args.has("keep") { arguments["keep"] = .bool(true) }
            return try plan("handle_review_item", arguments, view: .handled)
        case "close":
            let request = try positional(1, "request")
            try noMorePositionals(than: 2)
            var arguments: [String: JSONValue] = ["request": .string(request)]
            if args.has("force") { arguments["force"] = .bool(true) }
            return try plan("close_review", arguments, view: .closed)
        case "wait":
            try noMorePositionals(than: 1)
            var arguments: [String: JSONValue] = [:]
            let card = args.value("card")
            if let card { arguments["card"] = .string(card) }
            if let timeout = args.value("timeout") {
                guard let seconds = Double(timeout), seconds >= 0 else { throw CLIError.usage("review wait: --timeout is a number of seconds.") }
                arguments["timeout_seconds"] = .number(seconds)
            }
            return try plan("wait_for_reviews", arguments, card: card, view: .reviews)
        default:
            throw CLIError.usage("review: unknown \"\(sub)\". Use show, handle, close or wait. See `tasks review --help`.")
        }
    }

    func docs() throws -> Plan {
        switch positionals.first {
        case nil, "list":
            return try plan("list_docs", [:], view: .docs)
        case "show", "get":
            let path = try positional(1, "path")
            return try plan("get_doc", ["path": .string(path)], view: .doc)
        case "search":
            let query = positionals.dropFirst().joined(separator: " ")
            guard !query.isEmpty else { throw CLIError.usage("docs search: say what to look for.") }
            return try plan("search_docs", ["query": .string(query)], view: .docHits)
        case let other?:
            throw CLIError.usage("docs: unknown \"\(other)\". Use show or search. See `tasks docs --help`.")
        }
    }

    // MARK: Raw

    func raw() throws -> Plan {
        let tool = try positional(0, "tool")
        try noMorePositionals(than: 2)
        guard let definition = AgentTools.all.first(where: { $0.name == tool }) else {
            throw CLIError.usage("The app has no tool \"\(tool)\". `tasks tools` lists them.")
        }
        var arguments: [String: JSONValue] = [:]
        if positionals.count > 1 {
            let text = positionals[1] == "-" ? String(decoding: input.stdin(), as: UTF8.self) : positionals[1]
            guard case .object(let object)? = try? JSONValue.parse(text) else {
                throw CLIError.usage("raw: the arguments must be a JSON object, e.g. tasks raw get_card '{\"board\": \"GitKittie\", \"card\": \"GKM-123\"}'")
            }
            arguments = object
        }
        let properties = ToolSchema(definition).properties
        if arguments["agent"] == nil, properties.contains("agent"), let agent = args.value("agent") ?? env("TASKS_AGENT") {
            arguments["agent"] = .string(agent)
        }
        if arguments["board"] == nil, properties.contains("board") {
            if let board = givenBoard {
                arguments["board"] = .string(board)
            } else if let card = arguments["card"]?.string {
                return Plan(tool: tool, arguments: arguments, board: .fromCard(card, fallback: nil), view: .raw)
            }
        }
        return Plan(tool: tool, arguments: arguments, board: .none, view: .raw)
    }
}

/// The parts of a tool's input schema the CLI reads.
public struct ToolSchema {
    public let properties: [String]
    public let required: [String]

    public init(_ tool: MCPTool) {
        let object = (try? JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8))) as? [String: Any] ?? [:]
        properties = ((object["properties"] as? [String: Any])?.keys).map { Array($0).sorted() } ?? []
        required = object["required"] as? [String] ?? []
    }
}
