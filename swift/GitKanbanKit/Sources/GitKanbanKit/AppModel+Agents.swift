import Foundation
import GitKittieKit

// Agent access: a local MCP server (`MCPServer.swift`) through which an agent reads and
// changes the boards in the app's sidebar, without having their repository on disk. The
// app fetches what a tool call needs and writes each change to the board's source at once
// (a repository through the provider API, a folder as files), so an agent knows a change
// landed when the call returns.

extension AppModel {
    private var agentEnabledKey: String { "gitkanban.agentAccessEnabled" }
    private var agentPortKey: String { "gitkanban.agentAccessPort" }
    public static let defaultAgentPort = 47_810

    /// The token lives in a file only this user can read, next to the bridge that needs to
    /// read it. (Not in the keychain: the bridge is a shell script and cannot use it, so the
    /// token is on disk either way, and a keychain item made by one build of the app makes
    /// macOS stop every other build with a permission prompt at launch.)
    private var agentTokenFile: URL { agentBridgeDirectory.appendingPathComponent("token") }

    public var agentAccessEnabled: Bool { defaults.bool(forKey: agentEnabledKey) }

    public var agentPort: Int {
        get { let port = defaults.integer(forKey: agentPortKey); return (1024...65_535).contains(port) ? port : Self.defaultAgentPort }
        set { defaults.set(newValue, forKey: agentPortKey) }
    }

    /// The token agents authenticate with, made on first use.
    public func agentToken() -> String {
        if let existing = try? String(contentsOf: agentTokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count >= 32 { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let manager = FileManager.default
        try? manager.createDirectory(at: agentBridgeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? Data(token.utf8).write(to: agentTokenFile, options: .atomic)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: agentTokenFile.path)
        return token
    }

    /// A new token: every agent that talks HTTP directly with the old one is locked out.
    /// Agents that use the bridge pick the new one up by themselves.
    public func resetAgentToken() async {
        try? FileManager.default.removeItem(at: agentTokenFile)
        if agentAccessEnabled { await startAgentServer() }
    }

    public func setAgentAccess(_ enabled: Bool) async {
        defaults.set(enabled, forKey: agentEnabledKey)
        if enabled { await startAgentServer() } else { await stopAgentServer() }
    }

    /// Start the server when agent access is on (app launch).
    public func startAgentServerIfEnabled() async {
        if agentAccessEnabled, agentServer == nil { await startAgentServer() }
    }

    public var agentServerURL: String { "http://127.0.0.1:\(agentServerPort ?? agentPort)/mcp" }

    // MARK: Bridge

    /// Where the bridge script and its connection file live: the app's own Application
    /// Support folder, which stays put wherever the app itself is.
    public var agentBridgeDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.hakobs.gitkanban", isDirectory: true)
            .appendingPathComponent("AgentAccess", isDirectory: true)
    }

    public var agentBridgeScript: URL { agentBridgeDirectory.appendingPathComponent("tasks-mcp.sh") }

    /// Write the bridge an agent starts instead of talking HTTP itself, and the file that
    /// tells it the port and token. The bridge opens the app when it is not running, which
    /// a plain HTTP connection cannot do. Both files are readable by this user only.
    func writeAgentBridge() {
        let directory = agentBridgeDirectory
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // `app` is this very copy of the app: the bridge opens it by path, because opening by
            // bundle id can start another (older) copy that happens to be installed.
            let connection: [String: Any] = ["port": agentServerPort ?? agentPort, "token": agentToken(),
                                             "app": Bundle.main.bundlePath]
            let file = directory.appendingPathComponent("connection.json")
            try JSONSerialization.data(withJSONObject: connection).write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let script = AgentBridge.script(bundleID: Bundle.main.bundleIdentifier ?? "app.hakobs.gitkanban")
            try Data(script.utf8).write(to: agentBridgeScript, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agentBridgeScript.path)
        } catch {
            agentServerError = "The agent bridge could not be written: \(error.localizedDescription)"
        }
    }

    func stopAgentServer() async {
        await agentServer?.stop()
        agentServer = nil
        agentServerPort = nil
        agentServerError = nil
    }

    func startAgentServer() async {
        await stopAgentServer()
        let dispatcher = MCPDispatcher(
            serverName: "tasks", serverVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1",
            instructions: AgentTools.instructions, tools: AgentTools.all
        ) { [weak self] name, arguments in
            guard let self else { throw AgentBoardError("The Tasks app is shutting down.") }
            return try await self.runAgentTool(name, arguments: arguments)
        }
        let server = MCPHTTPServer(token: agentToken(), dispatcher: dispatcher)
        do {
            agentServerPort = Int(try await server.start(port: UInt16(agentPort)))
            agentServer = server
            writeAgentBridge()
        } catch {
            agentServerError = "Could not listen on port \(agentPort): \(error.localizedDescription)"
        }
    }

    // MARK: Boards

    /// How a tool names a board: the repository's (or folder's) name, a slash, the board's folder.
    static func agentReference(_ repo: AddedRepo, _ board: SelectedBoard) -> String {
        board.folder.isEmpty ? repo.name : "\(repo.name)/\(board.folder)"
    }

    /// The folder a repo's boards sit in ("" when they are at its root, "Tasks" for "Tasks/Pets").
    static func boardParent(of repo: AddedRepo) -> String {
        var counts: [String: Int] = [:]
        for board in repo.boards where !board.folder.isEmpty {
            counts[board.folder.lastIndex(of: "/").map { String(board.folder[..<$0]) } ?? "", default: 0] += 1
        }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? ""
    }

    /// The repo a tool call means by name; with none given, the only one there is.
    func agentRepo(_ wanted: String?) throws -> AddedRepo {
        if let key = wanted?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !key.isEmpty {
            if let repo = addedRepos.first(where: { $0.name.lowercased() == key || $0.fullName.lowercased() == key }) { return repo }
            throw AgentBoardError("No repository \"\(wanted ?? "")\" in the Tasks app. There \(addedRepos.count == 1 ? "is" : "are"): \(addedRepos.map(\.name).joined(separator: ", ")).")
        }
        if addedRepos.count == 1 { return addedRepos[0] }
        if addedRepos.isEmpty { throw AgentBoardError("The Tasks app has no repository or folder added yet. Add one in the app first.") }
        throw AgentBoardError("Say which repository: \(addedRepos.map(\.name).joined(separator: ", ")).")
    }

    /// Put a board in the sidebar (an agent used or made it), so it shows in the app too.
    @discardableResult
    func adoptBoard(folder: String, in repo: AddedRepo) -> (repo: AddedRepo, board: SelectedBoard) {
        let name = folder.split(separator: "/").last.map(String.init) ?? repo.name
        let board = SelectedBoard(folder: folder, name: name)
        if let current = addedRepos.first(where: { $0.id == repo.id }), !current.boards.contains(where: { $0.folder == folder }) {
            setBoards(current.boards + [board], for: repo.id)
        }
        let updated = addedRepos.first { $0.id == repo.id } ?? repo
        return (updated, updated.boards.first { $0.folder == folder } ?? board)
    }

    /// Folders next to a repo's boards that are not in the sidebar yet.
    func otherBoardFolders(in repo: AddedRepo) async -> [String] {
        guard let source = try? agentSource(for: repo) else { return [] }
        let parent = Self.boardParent(of: repo)
        let known = Set(repo.boards.map { $0.folder.lowercased() })
        let entries = (try? await source.list(parent)) ?? []
        return entries
            .filter { $0.kind == .directory && !$0.name.hasPrefix(".") && !["attachments", "review", "node_modules"].contains($0.name) }
            .map { parent.isEmpty ? $0.name : "\(parent)/\($0.name)" }
            .filter { !known.contains($0.lowercased()) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The board a tool call means: its reference, or just its name or folder when only one
    /// matches. A board that is in an added repository but not in the sidebar yet is found
    /// too, and put in the sidebar.
    func agentBoard(_ wanted: String) async throws -> (repo: AddedRepo, board: SelectedBoard) {
        let key = wanted.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { throw AgentBoardError("Say which board. Use list_boards to see them.") }
        let all = addedRepos.flatMap { repo in repo.boards.map { (repo: repo, board: $0) } }
        if let exact = all.first(where: { Self.agentReference($0.repo, $0.board).lowercased() == key }) { return exact }
        let loose = all.filter {
            $0.board.name.lowercased() == key || $0.board.folder.lowercased() == key
                || $0.board.folder.split(separator: "/").last.map { $0.lowercased() } == key
        }
        if loose.count == 1 { return loose[0] }
        if loose.count > 1 {
            throw AgentBoardError("\"\(wanted)\" matches several boards: \(loose.map { Self.agentReference($0.repo, $0.board) }.joined(separator: ", ")). Use one of those.")
        }
        // Not in the sidebar: look for it in the added repositories.
        var found: [(AddedRepo, String)] = []
        for repo in addedRepos {
            let prefix = repo.name.lowercased() + "/"
            let rest = key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : (key.contains("/") ? nil : key)
            guard let rest else { continue }
            for folder in await otherBoardFolders(in: repo)
            where folder.lowercased() == rest || folder.split(separator: "/").last.map({ $0.lowercased() }) == rest {
                found.append((repo, folder))
            }
        }
        if found.count == 1 { return adoptBoard(folder: found[0].1, in: found[0].0) }
        if found.count > 1 {
            throw AgentBoardError("\"\(wanted)\" matches several boards: \(found.map { "\($0.0.name)/\($0.1)" }.joined(separator: ", ")). Use one of those.")
        }
        throw AgentBoardError("No board \"\(wanted)\". Use list_boards to see the boards, or create_board to make a new one.")
    }

    /// Where an agent's reads and writes for a repo go: straight to the provider or folder,
    /// not through the app's send-later queue, so a call that returns has really landed.
    func agentSource(for repo: AddedRepo) throws -> any BoardWritable {
        if repo.kind.isFolder {
            if let source = folderSource(for: repo) { return source }
            throw AgentBoardError("The folder \(repo.name) cannot be opened by the Tasks app right now.")
        }
        if let source = remoteSource(for: repo) { return source }
        throw AgentBoardError("The Tasks app is not signed in to the git provider. Open the app and sign in.")
    }

    /// After an agent changed a board: show it, if that board is on screen, and recount it.
    private func agentDidChange(_ repo: AddedRepo, _ folder: String) async {
        if activeRepo?.id == repo.id, activeBoardFolder == folder, let project = selectedProject {
            await selectProject(project)
        }
        await loadBoardSummary(repo, folder, force: true)
    }

    // MARK: Tools

    func runAgentTool(_ name: String, arguments: Data) async throws -> String {
        let args = (try? JSONSerialization.jsonObject(with: arguments) as? [String: Any]) ?? [:]
        func string(_ key: String) -> String? { (args[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func required(_ key: String) throws -> String {
            guard let value = string(key) else { throw AgentBoardError("Missing \"\(key)\".") }
            return value
        }
        func fields() throws -> [(key: String, value: AgentFieldValue)] {
            guard let raw = args["fields"] else { return [] }
            guard let object = raw as? [String: Any] else { throw AgentBoardError("\"fields\" must be an object of frontmatter keys.") }
            return try object.keys.sorted().map { key in
                guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                    throw AgentBoardError("\"\(key)\" is not a frontmatter key.")
                }
                guard let value = AgentFieldValue(json: object[key] as Any) else {
                    throw AgentBoardError("\"\(key)\" must be a string, number, boolean, null or a list of strings.")
                }
                return (key, value)
            }
        }
        func json(_ value: Any) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }

        if name == "list_boards" {
            var boards: [[String: Any]] = []
            for repo in addedRepos {
                let source = repo.kind.isFolder ? "folder" : repo.fullName
                for board in repo.boards {
                    boards.append(["board": Self.agentReference(repo, board), "name": board.name, "source": source, "in_app_sidebar": true])
                }
                // Every other board of the repository is usable too; it joins the sidebar on first use.
                for folder in await otherBoardFolders(in: repo) {
                    boards.append(["board": "\(repo.name)/\(folder)", "name": folder.split(separator: "/").last.map(String.init) ?? folder,
                                   "source": source, "in_app_sidebar": false])
                }
            }
            return json(boards)
        }
        if name == "create_board" {
            let repo = try agentRepo(string("repository"))
            let made = try await AgentBoardFactory.create(
                source: try agentSource(for: repo), parent: Self.boardParent(of: repo), name: try required("name"),
                description: string("description"), agent: try required("agent"), lanePlaceholders: !repo.kind.isFolder)
            let adopted = adoptBoard(folder: made.folder, in: repo)
            await loadBoardSummary(adopted.repo, made.folder, force: true)
            return json(["board": Self.agentReference(adopted.repo, adopted.board), "folder": made.folder, "lanes": made.lanes])
        }

        let (repo, selected) = try await agentBoard(try required("board"))
        let board = AgentBoard(source: try agentSource(for: repo), folder: selected.folder)
        switch name {
        case "get_board":
            return json(try await board.describe())
        case "get_board_rules":
            return json(try await board.rules())
        case "list_cards":
            return json(try await board.listCards(lane: string("lane"), query: string("query"), assignee: string("assignee"),
                                                 limit: args["limit"] as? Int ?? 200))
        case "get_card":
            return json(try await board.getCard(try required("card")))
        case "create_card":
            let result = try await board.createCard(title: try required("title"), lane: string("lane"), body: string("body"),
                                                    fields: try fields(), createdBy: try required("agent"))
            await agentDidChange(repo, selected.folder)
            return json(result)
        case "update_card":
            let result = try await board.updateCard(try required("card"), fields: try fields(), body: string("body"),
                                                    lane: string("lane"), activity: string("activity"), agent: try required("agent"))
            await agentDidChange(repo, selected.folder)
            return json(result)
        case "claim_card":
            let result = try await board.claimCard(try required("card"), agent: try required("agent"),
                                                   hours: args["hours"] as? Double ?? 24, branch: string("working_branch"))
            await agentDidChange(repo, selected.folder)
            return json(result)
        case "attach_file":
            guard let data = Data(base64Encoded: try required("content_base64"), options: .ignoreUnknownCharacters) else {
                throw AgentBoardError("\"content_base64\" is not valid base64.")
            }
            let result = try await board.attach(try required("card"), fileName: try required("file_name"), data: data)
            await agentDidChange(repo, selected.folder)
            return json(result)
        default:
            throw AgentBoardError("Unknown tool \(name).")
        }
    }
}

/// The bridge between an agent and the app: a stdio MCP server in a few lines of shell.
/// It forwards each JSON-RPC line to the app's HTTP endpoint, and when nothing answers it
/// opens the app in the background, waits for it, and tries again.
enum AgentBridge {
    static func script(bundleID: String) -> String {
        #"""
        #!/bin/bash
        # Tasks agent bridge. Written by the Tasks app; changes here are overwritten.
        # Usage (as an MCP server command): /bin/bash "<this file>"
        DIR="$(cd "$(dirname "$0")" && pwd)"
        CONNECTION="$DIR/connection.json"
        BUNDLE="\#(bundleID)"

        load() {
          PORT="$(/usr/bin/plutil -extract port raw -o - "$CONNECTION" 2>/dev/null)"
          TOKEN="$(/usr/bin/plutil -extract token raw -o - "$CONNECTION" 2>/dev/null)"
          APP="$(/usr/bin/plutil -extract app raw -o - "$CONNECTION" 2>/dev/null)"
        }

        post() {
          printf '%s' "$1" | /usr/bin/curl -sS --max-time 300 -X POST "http://127.0.0.1:${PORT}/mcp"             -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json"             -H "Accept: application/json, text/event-stream" --data-binary @- 2>/dev/null
        }

        # Open Tasks in the background and wait until it listens.
        wake() {
          if [ -n "$APP" ] && [ -d "$APP" ]; then /usr/bin/open -g "$APP" 2>/dev/null; else /usr/bin/open -g -b "$BUNDLE" 2>/dev/null; fi
          for _ in $(seq 1 60); do
            sleep 0.5
            load
            if [ -n "$PORT" ] && /usr/bin/nc -z 127.0.0.1 "$PORT" 2>/dev/null; then return 0; fi
          done
          return 1
        }

        fail() {
          local id kind
          kind="$(printf '%s' "$1" | /usr/bin/plutil -type id - 2>/dev/null)"
          id="$(printf '%s' "$1" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null)"
          [ "$kind" = "string" ] && id="\"$id\""
          # A notification has no id and gets no answer.
          [ -n "$id" ] && printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"%s"}}\n' "$id" "$2"
        }

        load
        while IFS= read -r line || [ -n "$line" ]; do
          [ -z "$line" ] && continue
          response="$(post "$line")"
          status=$?
          if [ $status -ne 0 ]; then
            if wake; then
              response="$(post "$line")"
              status=$?
            fi
          fi
          if [ $status -ne 0 ]; then
            fail "$line" "The Tasks app could not be reached. Open Tasks and turn on Agent Access (account menu)."
            continue
          fi
          [ -n "$response" ] && printf '%s\n' "$response"
        done
        """#
    }
}

/// The tools the agent server offers, and how to use them.
enum AgentTools {
    static let instructions = """
    This is Sil's task board, served by the Tasks app. Use these tools for everything on the board instead of \
    reading or writing card files in a repository. Start with list_boards. Before your first change on a board, \
    read get_board_rules once: it is the board's contract (fields, lanes, lifecycle) and it wins over anything \
    written here. Claim a card with claim_card before you implement it. Keep the card current while you work with \
    update_card (fields, an activity entry, a move to another lane). Every change is written and committed at once; \
    a call that returns without error has landed. Never set read_at or read_by.
    """

    private static let board = #""board": {"type": "string", "description": "The board, as list_boards names it (e.g. tasks/GitKittie), or just its name when that is unambiguous."}"#
    private static let card = #""card": {"type": "string", "description": "The card's id (e.g. GITKITTIE-021) or its file name."}"#
    private static let agent = #""agent": {"type": "string", "description": "Your canonical agent handle (e.g. hermio), recorded on the card."}"#
    private static let fields = #""fields": {"type": "object", "description": "Top-level frontmatter keys to set, e.g. {\"priority\": \"P1\", \"blocked\": true, \"commits\": [\"abc123\"], \"reviewer\": null}. Values: string, number, boolean, null, or a list of strings. Other keys are left as they are.", "additionalProperties": true}"#

    static let all: [MCPTool] = [
        MCPTool(name: "list_boards", description: "List every board you can use: the ones in the Tasks app's sidebar and the other boards in the same repositories.",
                inputSchema: #"{"type": "object", "properties": {}}"#),
        MCPTool(name: "create_board", description: "Create a new, empty board for a project in a repository that already holds boards. It inherits the repository's lanes and appears in the app. Check list_boards first: do not create a board for a project that already has one under a slightly different name.",
                inputSchema: #"{"type": "object", "properties": {"name": {"type": "string", "description": "The board's name, normally the project's name. It becomes the folder name."}, "description": {"type": "string", "description": "One or two sentences on what the board is for."}, "repository": {"type": "string", "description": "Which repository, when the app has more than one (as list_boards shows under source)."}, \#(agent)}, "required": ["name", "agent"]}"#),
        MCPTool(name: "get_board", description: "A board's lanes (with their status values and card counts), priorities, types, epics, users and card id prefix.",
                inputSchema: #"{"type": "object", "properties": {\#(board)}, "required": ["board"]}"#),
        MCPTool(name: "get_board_rules", description: "Everything written down about how to work on a board: the repository's contract and rule files (README.md, AGENTS.md, RULES.md), the card template, and the board's own README and rule files, which win where they differ. Read once before changing a board.",
                inputSchema: #"{"type": "object", "properties": {\#(board)}, "required": ["board"]}"#),
        MCPTool(name: "list_cards", description: "Cards on a board with their main fields (id, title, lane, status, priority, type, assignee, picked_up_by, updated_at). Start with lane \"in-progress\" to see where work was left off.",
                inputSchema: #"{"type": "object", "properties": {\#(board), "lane": {"type": "string", "description": "A lane id, name or status. Omit for all lanes."}, "query": {"type": "string", "description": "Text to find in id or title."}, "assignee": {"type": "string", "description": "Only cards assigned to or claimed by this id."}, "limit": {"type": "integer"}}, "required": ["board"]}"#),
        MCPTool(name: "get_card", description: "One card: its full Markdown text, lane, path and attachment names.",
                inputSchema: #"{"type": "object", "properties": {\#(board), \#(card)}, "required": ["board", "card"]}"#),
        MCPTool(name: "create_card", description: "Create a card from the board's template with the next free id. Without a body the template's sections are kept for you to fill in with update_card.",
                inputSchema: #"{"type": "object", "properties": {\#(board), "title": {"type": "string"}, "lane": {"type": "string", "description": "Lane id, name or status. Defaults to the to-do lane."}, "body": {"type": "string", "description": "The card's Markdown body without the title heading."}, \#(fields), \#(agent)}, "required": ["board", "title", "agent"]}"#),
        MCPTool(name: "update_card", description: "Change a card: set frontmatter fields, replace the body, move it to another lane (sets status), and/or append an activity log entry. updated_at is set for you.",
                inputSchema: #"{"type": "object", "properties": {\#(board), \#(card), \#(fields), "body": {"type": "string", "description": "The whole new Markdown body (everything below the frontmatter). Omit to keep it."}, "lane": {"type": "string", "description": "Lane id, name or status to move the card to."}, "activity": {"type": "string", "description": "What happened, as one sentence; written to the activity log with the time and your handle."}, \#(agent)}, "required": ["board", "card", "agent"]}"#),
        MCPTool(name: "claim_card", description: "Claim a card before implementing it: records you as the owner with a lease, moves it to In Progress. Refused when another owner holds an unexpired claim.",
                inputSchema: #"{"type": "object", "properties": {\#(board), \#(card), \#(agent), "hours": {"type": "number", "description": "Lease length, default 24."}, "working_branch": {"type": "string"}}, "required": ["board", "card", "agent"]}"#),
        MCPTool(name: "attach_file", description: "Attach a file (a screenshot) to a card.",
                inputSchema: #"{"type": "object", "properties": {\#(board), \#(card), "file_name": {"type": "string"}, "content_base64": {"type": "string"}}, "required": ["board", "card", "file_name", "content_base64"]}"#),
    ]
}
