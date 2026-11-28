import Foundation

// The `tasks` command line's commands, options, environment and exit codes, as data. The CLI
// (`TasksCLIKit`) parses with this table and prints its help from it, and the agent guide
// (`AgentGuide`) prints its reference from it, so the guide cannot describe a command the CLI
// does not have. It lives here, next to the tool list, because the app's agent server serves
// the same guide (`get_agent_guide`) and does not link the CLI.

/// One option a command takes.
public struct OptionSpec: Sendable {
    public let name: String
    public let short: Character?
    /// What the value is called in help (`<lane>`); nil for a flag.
    public let value: String?
    public let help: String

    public init(_ name: String, short: Character? = nil, value: String? = nil, _ help: String) {
        self.name = name
        self.short = short
        self.value = value
        self.help = help
    }

    public var takesValue: Bool { value != nil }

    /// `-b, --board <board>`
    public var label: String {
        var label = short.map { "-\($0), " } ?? ""
        label += "--\(name)"
        if let value { label += " <\(value)>" }
        return label
    }
}

/// A command: its words, help, options and examples.
public struct CommandSpec: Sendable {
    public let name: String
    public var aliases: [String] = []
    public let usage: [String]
    public let summary: String
    /// The server tools it calls (shown in help with their description).
    public let tools: [String]
    public var options: [OptionSpec] = []
    public var notes: String?
    /// Real command lines, each one parsed by a test.
    public var examples: [String] = []
    /// What `--json` prints.
    public var returns: String?
}

/// An environment variable the CLI reads.
public struct EnvironmentSpec: Sendable {
    public let name: String
    public let help: String
}

/// Why the CLI stopped, as an exit code.
public enum ExitStatus: Int32, CaseIterable, Sendable {
    case done = 0
    case refused = 1
    case usage = 2
    case unreachable = 3
    case auth = 4
    case notSetUp = 5

    /// The `kind` of a `--json` error.
    public var kind: String {
        switch self {
        case .done: "done"
        case .refused: "refused"
        case .usage: "usage"
        case .unreachable: "unreachable"
        case .auth: "auth"
        case .notSetUp: "not_set_up"
        }
    }

    public var meaning: String {
        switch self {
        case .done: "Success. For a change: it has landed (written and committed by the app)."
        case .refused: "The app answered and refused: unknown card, board, lane or page, a value the board doesn't allow, someone else's live claim, a page that changed since you read it."
        case .usage: "The command line is wrong: unknown command or option, a missing argument, no board, no --agent / TASKS_AGENT."
        case .unreachable: "Tasks is not running and could not be opened, or it did not answer."
        case .auth: "The app turned the token down."
        case .notSetUp: "Agent Access was never turned on on this Mac: there is nothing to connect to."
        }
    }

    public var whatToDo: String {
        switch self {
        case .done: "Carry on."
        case .refused: "Read the message: it names what is wrong and the values that are allowed. Fix the call. Someone else's claim: choose another card; never edit their claim to get around it."
        case .usage: "Fix the command line; `tasks <command> --help` shows its options."
        case .unreachable: "Ask the person to open Tasks (with TASKS_NO_WAKE set, the tool will not open it itself). Do not fall back to curl."
        case .auth: "Ask the person to turn Agent Access off and on again in Tasks. Never read or copy the token yourself."
        case .notSetUp: "Ask the person to open Tasks ▸ account menu ▸ Agent Access… ▸ Let agents connect."
        }
    }
}

public enum CommandTable {
    public static let global: [OptionSpec] = [
        OptionSpec("json", "Print the app's JSON answer instead of a table or card (for scripts and agents)."),
        OptionSpec("board", short: "b", value: "board", "The board, as `tasks boards` names it, or just its name. Default: $TASKS_BOARD."),
        OptionSpec("agent", value: "handle", "Your handle, recorded on cards you change. Default: $TASKS_AGENT."),
        OptionSpec("help", short: "h", "Show help."),
    ]

    public static let environment: [EnvironmentSpec] = [
        EnvironmentSpec(name: "TASKS_AGENT", help: "your handle (claude, codex, …), required for changes"),
        EnvironmentSpec(name: "TASKS_BOARD", help: "the board to use when none is given"),
        EnvironmentSpec(name: "TASKS_NO_WAKE=1", help: "never open the app; fail when it is not running"),
        EnvironmentSpec(name: "TASKS_CONNECTION", help: "path of the connection.json to use (default: the app's AgentAccess folder)"),
        EnvironmentSpec(name: "TASKS_CACHE_DIR", help: "where to remember which board numbers which cards (default: the user's Caches folder)"),
    ]

    public static let fieldOptions: [OptionSpec] = [
        OptionSpec("description", short: "d", value: "markdown", "The card's whole Markdown body (below the frontmatter)."),
        OptionSpec("body", value: "markdown", "Same as --description."),
        OptionSpec("body-file", value: "path|-", "Read the body from a file, or `-` for standard input."),
        OptionSpec("priority", short: "p", value: "P1", "Priority, as the board defines them (`tasks board`)."),
        OptionSpec("type", value: "type", "Card type, as the board defines them."),
        OptionSpec("assignee", value: "id", "Assignee (a user id on the board), or `null`."),
        OptionSpec("epic", value: "id", "Epic id, or `null`."),
        OptionSpec("tags", value: "a,b", "Tags, comma separated (replaces the list). Empty for none."),
        OptionSpec("set", value: "key=value", "Set any frontmatter key; repeatable. null/true/false and [..] are typed, everything else is text."),
        OptionSpec("lane", short: "l", value: "lane", "Lane id, name or status (todo, in-progress, in-review, testing, done)."),
    ]

    private static let cardChange = "`{\"id\", \"file\", \"path\", \"lane\", \"moved\"}`: the card's id, file name, path and lane after the change."

    public static let all: [CommandSpec] = [
        CommandSpec(name: "guide", usage: ["tasks guide [--board <board>]"],
                    summary: "This guide: how to work on the boards, every command and tool. Read it once before anything else.",
                    tools: ["get_agent_guide", "get_board_rules"],
                    notes: "Works without the app; --board appends that board's rules, fetched from the app. The same text as the get_agent_guide tool.",
                    examples: ["tasks guide", "tasks guide --board MyProject", "tasks guide --json"],
                    returns: "The guide as one JSON string."),
        CommandSpec(name: "boards", usage: ["tasks boards"], summary: "List the boards you can use.", tools: ["list_boards"],
                    examples: ["tasks boards", "tasks boards --json"],
                    returns: "`[{\"board\", \"name\", \"source\", \"in_app_sidebar\"}]`. `board` is the name every other command takes."),
        CommandSpec(name: "board", usage: ["tasks board [<board>]"], summary: "A board's lanes, priorities, types, users and id prefixes.", tools: ["get_board"],
                    examples: ["tasks board MyProject", "tasks board MyProject --json"],
                    returns: "`{\"name\", \"folder\", \"card_id_prefix\", \"lanes\": [{\"id\", \"name\", \"status\", \"cards\", \"backlog\", \"terminal\"}], \"priorities\", \"types\", \"epics\", \"users\", \"products\"}`: the values card fields may take."),
        CommandSpec(name: "rules", usage: ["tasks rules [<board>]"], summary: "The board's contract and rule files. Read once before changing a board.", tools: ["get_board_rules"],
                    examples: ["tasks rules MyProject"],
                    returns: "`{\"contract\", \"template\", \"repository_AGENTS.md\", \"board_readme\", \"board_AGENTS.md\", \"precedence\"}`: each file's text (only the files that exist)."),
        CommandSpec(name: "list", aliases: ["ls", "cards"], usage: ["tasks list [--board <board>] [--lane <lane>] [--mine] [--query <text>]", "tasks list --all --mine"],
                    summary: "Cards on a board, with their main fields.", tools: ["list_cards"],
                    options: [
                        OptionSpec("lane", short: "l", value: "lane", "Only this lane (todo, in-progress, in-review, testing, done, or a lane name)."),
                        OptionSpec("mine", "Only cards assigned to or claimed by you (--agent / $TASKS_AGENT)."),
                        OptionSpec("assignee", value: "id", "Only cards assigned to or claimed by this id."),
                        OptionSpec("query", short: "q", value: "text", "Only cards whose id or title contains this."),
                        OptionSpec("limit", value: "n", "At most this many cards per board (default 200)."),
                        OptionSpec("all", "Every board in the app's sidebar (one call per board)."),
                    ],
                    examples: ["tasks list --board MyProject --lane in-progress", "tasks list --board MyProject --lane todo --json", "tasks list --all --mine"],
                    returns: "`[{\"id\", \"title\", \"lane\", \"lane_id\", \"status\", \"priority\", \"type\", \"epic\", \"assignee\", \"picked_up_by\", \"claim_expires_at\", \"blocked\", \"updated_at\", \"file\"}]` (with `--all`, each also has `board`)."),
        CommandSpec(name: "show", aliases: ["get", "card"], usage: ["tasks show <card>"], summary: "One card: its fields, body, lane and attachments.", tools: ["get_card"],
                    notes: "The board is found from the card's id prefix (GKM-123 → the board that numbers GKM cards) unless --board is given.",
                    examples: ["tasks show PROJ-12", "tasks show PROJ-12 --json"],
                    returns: "`{\"id\", \"file\", \"path\", \"lane\", \"lane_id\", \"text\", \"attachments\"}`; `text` is the whole card, frontmatter and body."),
        CommandSpec(name: "create", aliases: ["new", "add"], usage: ["tasks create --board <board> --title <title> [field options]", "tasks create --board <board> '<json>'"],
                    summary: "Create a card with the next free id.", tools: ["create_card"],
                    options: [OptionSpec("title", short: "t", value: "title", "The card's title (or give it as the first argument).")] + fieldOptions,
                    notes: "A JSON object may replace the options: {\"title\": \"…\", \"description\": \"…\", \"lane\": \"todo\", \"priority\": \"P1\", \"fields\": {…}}. Keys other than title, description/body, lane and fields are frontmatter fields.",
                    examples: ["tasks create --board MyProject --title \"Fix the sync badge\" --priority P2 --type fix --body-file card.md",
                               "tasks create --board MyProject '{\"title\": \"Fix the sync badge\", \"priority\": \"P2\", \"description\": \"## Context\\n\\nThe badge stays red.\"}' --json"],
                    returns: "`{\"id\", \"file\", \"path\", \"lane\"}`: the new card's id (the next free one), file name, path and lane."),
        CommandSpec(name: "update", aliases: ["edit", "set"], usage: ["tasks update <card> [field options] [--activity <text>]", "tasks update <card> '<json>'"],
                    summary: "Change a card's fields or body, move it, and/or log what happened.", tools: ["update_card"],
                    options: [OptionSpec("title", short: "t", value: "title", "A new title (the frontmatter field).")] + fieldOptions
                        + [OptionSpec("activity", short: "m", value: "text", "One sentence for the card's activity log.")],
                    notes: "A JSON object may replace the options: {\"description\": \"…\", \"priority\": \"P1\", \"lane\": \"review\", \"activity\": \"…\"}. Keys other than description/body, lane, activity and fields are frontmatter fields.",
                    examples: ["tasks update PROJ-12 --body-file card.md --activity \"Narrowed the scope: the toolbar draws the badge.\"",
                               "tasks update PROJ-12 --set blocked=true --set \"blocked_reason=Waiting for the API key\" -m \"Blocked on the API key.\"",
                               "tasks update PROJ-12 '{\"pull_request\": \"https://example.com/pull/7\", \"commits\": [\"a1b2c3d\"], \"activity\": \"Opened PR #7.\"}' --json"],
                    returns: cardChange),
        CommandSpec(name: "move", aliases: ["mv"], usage: ["tasks move <card> <lane> [--activity <text>]"], summary: "Move a card to another lane (sets its status).", tools: ["update_card"],
                    options: [OptionSpec("activity", short: "m", value: "text", "One sentence for the card's activity log.")],
                    notes: "Lanes: todo, in-progress, review (in-review), testing, done, or a lane's name.",
                    examples: ["tasks move PROJ-12 review --activity \"Opened PR #7; Handoff filled in.\"", "tasks move PROJ-12 in-progress -m \"Review asked for changes.\" --json"],
                    returns: cardChange),
        CommandSpec(name: "claim", usage: ["tasks claim <card> [--hours <n>] [--branch <branch>]"],
                    summary: "Claim a card before implementing it; moves it to In Progress. Claiming your own card again renews the lease (the heartbeat).", tools: ["claim_card"],
                    options: [OptionSpec("hours", value: "n", "Lease length in hours (default 24)."), OptionSpec("branch", value: "branch", "The working branch, recorded on the card.")],
                    examples: ["tasks claim PROJ-12 --branch feat/sync-badge --hours 8", "tasks claim PROJ-12 --json"],
                    returns: cardChange),
        CommandSpec(name: "comment", aliases: ["log"], usage: ["tasks comment <card> <text>"], summary: "Add an entry to a card's activity log.", tools: ["update_card"],
                    notes: "`-` reads the text from standard input.",
                    examples: ["tasks comment PROJ-12 \"Tried a 12-frame cycle; still stutters on the iPad. Next: profile the decoder.\""],
                    returns: cardChange),
        CommandSpec(name: "attach", usage: ["tasks attach <card> <file> [--name <file name>]"], summary: "Attach a file (a screenshot) to a card.", tools: ["attach_file"],
                    options: [OptionSpec("name", value: "file name", "The name to store it under (default: the file's name).")],
                    notes: "`-` reads the file from standard input (needed when this copy of tasks is sandboxed).",
                    examples: ["tasks attach PROJ-12 after-small-phone.png", "tasks attach PROJ-12 - --name after-small-phone.png"],
                    returns: "`{\"id\", \"path\", \"bytes\"}`."),
        CommandSpec(name: "reviews", usage: ["tasks reviews [--board <board>] [--state to_handle|pending|all] [--card <card>]"],
                    summary: "Review requests: decisions and answers to act on, or what still waits for the reviewer.", tools: ["list_reviews"],
                    options: [
                        OptionSpec("state", value: "state", "to_handle (default), pending or all."),
                        OptionSpec("card", value: "card", "Only requests of this card (also picks the board)."),
                        OptionSpec("all", "Every board in the app's sidebar."),
                    ],
                    examples: ["tasks reviews --board MyProject", "tasks reviews --card PROJ-12 --state all --json"],
                    returns: "`[{\"request\", \"title\", \"card\", \"question\", \"for\", \"due\", \"outcome\", \"on_accept\", \"actions_run\", \"pending\", \"to_handle\", \"checks\": [{\"id\", \"url\", \"sizes\", \"checklist\", \"status\", \"results\", \"failed\"}], \"items\": [{\"id\", \"file\", \"kind\", \"status\", \"decided_by\", \"decided_at\", \"comments\", \"handled_at\", \"shipped_to\", \"to_handle\"}], \"questions\": [{\"id\", \"question\", \"options\", \"status\", \"answer\", \"answer_labels\", \"answer_other\", \"answered_by\", \"answered_at\", \"comments\", \"handled_at\", \"to_handle\"}]}]`."),
        CommandSpec(name: "review", usage: ["tasks review show <request>", "tasks review handle <request> <item> [--shipped-to <path>] [--keep]",
                                            "tasks review close <request> [--force]", "tasks review wait [--card <card>] [--timeout <seconds>]",
                                            "tasks review create --card <card> --title <title> [--file <path>]… [--on-accept <lane>] [--on-changes <lane>] [--for <user>]… ['<json>']",
                                            "tasks review check --card <card> --title <title> --url <url> --item <statement>… [--size <size>]… [--on-accept <lane>] ['<json>']",
                                            "tasks review file <request> <path> [-o <file>]"],
                    summary: "Ask for a review (files or a browser check); one request; record an entry as handled; close a request; wait for decisions; fetch a request's file.",
                    tools: ["create_review", "list_reviews", "handle_review_item", "close_review", "wait_for_reviews", "get_review_file"],
                    options: [
                        OptionSpec("title", value: "title", "create, check: the new request's title."),
                        OptionSpec("request", value: "id", "create, check: add to this existing request instead (a redo round)."),
                        OptionSpec("question", value: "text", "create, check: what the reviewer should do, in one line."),
                        OptionSpec("notes", value: "markdown", "create, check: notes under the request."),
                        OptionSpec("file", short: "f", value: "path", "create: a file to judge (repeatable); its id is its name, its kind follows from the extension."),
                        OptionSpec("url", value: "url", "check: the page, at an address the reviewer's phone can open."),
                        OptionSpec("size", value: "size", "check: phone-small, phone, phone-large, tablet, tablet-landscape, laptop, desktop, wide or WIDTHxHEIGHT (repeatable)."),
                        OptionSpec("appearance", value: "light|dark", "check: also check in this appearance (repeatable)."),
                        OptionSpec("item", value: "statement", "check: a checklist line, answered pass or fail per size (repeatable)."),
                        OptionSpec("check-id", value: "id", "check: the check's id (default: from the title)."),
                        OptionSpec("on-accept", value: "lane", "create, check: move --card to this lane when the request is accepted."),
                        OptionSpec("on-changes", value: "lane", "create, check: move --card here when changes are asked."),
                        OptionSpec("on-reject", value: "lane", "create, check: move --card here when it is rejected."),
                        OptionSpec("comment-on-changes", "create, check: copy the reviewer's comments to the card on changes."),
                        OptionSpec("comment-on-reject", "create, check: copy the reviewer's comments to the card on reject."),
                        OptionSpec("assign-on-changes", value: "user", "create, check: assign --card to this user on changes."),
                        OptionSpec("for", value: "user", "create, check: a board user who decides (repeatable). Default: anyone."),
                        OptionSpec("notify", value: "level", "create, check: urgent, normal (default) or silent."),
                        OptionSpec("due", value: "YYYY-MM-DD", "create, check: the day it is due."),
                        OptionSpec("output", short: "o", value: "file|-", "file: write the file here (`-` for standard output) instead of printing its JSON."),
                        OptionSpec("shipped-to", value: "path", "handle: where the approved file now lives."),
                        OptionSpec("keep", "handle: leave a finished request in place."),
                        OptionSpec("force", "close: also when items are still waiting or unhandled."),
                        OptionSpec("card", value: "card", "create, check: the card the request belongs to; wait: only requests of this card (also picks the board)."),
                        OptionSpec("timeout", value: "seconds", "wait: how long, up to 240 (default 120)."),
                    ],
                    notes: "create and check take a JSON object as well (the create_review arguments: items, checks, questions, per-entry on_accept …), merged over the options. Questions and per-file actions need the JSON (or `tasks raw create_review`).",
                    examples: ["tasks review show PROJ-12-sync-badge --board MyProject", "tasks review wait --card PROJ-12 --timeout 240",
                               "tasks review handle PROJ-12-sync-badge providers --board MyProject",
                               "tasks review handle PROJ-12-sync-badge icon-v2 --shipped-to Assets/icon.png --board MyProject --json",
                               "tasks review close PROJ-12-sync-badge --board MyProject",
                               "tasks review create --card PROJ-12 --title \"Site onboarding, round 1\" --question \"Check the new onboarding page.\" --on-accept testing --on-changes in-progress --comment-on-changes --for sil --file after-phone.png",
                               "tasks review check --card PROJ-12 --title \"Onboarding page\" --url https://preview.example.app/onboarding --size phone --size desktop --size 1080x1920 --item \"The headline fits without an awkward break\" --for sil --on-accept testing --on-changes in-progress",
                               "tasks review create --card PROJ-12 --title \"Pick a tone\" '{\"questions\": [{\"id\": \"tone\", \"question\": \"Which tone?\", \"options\": [{\"id\": \"calm\", \"label\": \"Calm\"}, {\"id\": \"bold\", \"label\": \"Bold\"}]}]}'",
                               "tasks review file PROJ-12-onboarding-page results/onboarding-page-phone.png -o phone.png --board MyProject"],
                    returns: "create, check: `{\"request\", \"folder\", \"items\", \"checks\", \"warnings\"}`; show: one request as `tasks reviews` gives it; wait: the list of what to handle (empty when the time ran out); handle: `{\"request\", \"item\", \"pending\", \"to_handle\"}`; close: `{\"request\", \"closed\"}`; file: `{\"request\", \"path\", \"bytes\", \"content_base64\"}`."),
        CommandSpec(name: "docs", usage: ["tasks docs [--board <board>]", "tasks docs show <path>", "tasks docs search <query>"],
                    summary: "The board's documentation pages: list, read, search.", tools: ["list_docs", "get_doc", "search_docs"],
                    notes: "Writing and deleting pages: `tasks raw write_doc '<json>'`, `tasks raw delete_doc '<json>'`.",
                    examples: ["tasks docs --board MyProject", "tasks docs show docs/plan.md --board MyProject", "tasks docs search sync badge --board MyProject --json"],
                    returns: "list: `{\"docs\": [{\"path\", \"title\", \"editable\"}]}`; show: the page with its `text`; search: `{\"hits\": [{\"path\", \"title\", \"line\", \"line_number\"}]}`."),
        CommandSpec(name: "create-board", usage: ["tasks create-board <name> [--description <text>] [--repository <name>]"],
                    summary: "Create a new, empty board. Check `tasks boards` first.", tools: ["create_board"],
                    options: [OptionSpec("description", short: "d", value: "text", "One or two sentences on what the board is for."),
                              OptionSpec("repository", value: "name", "Which repository, when the app has more than one.")],
                    examples: ["tasks create-board Website --description \"The marketing site and its copy.\""],
                    returns: "`{\"board\", \"folder\", \"lanes\"}`."),
        CommandSpec(name: "tools", usage: ["tasks tools [<tool>]"], summary: "The app's tools and their arguments (what `raw` can call).", tools: [],
                    examples: ["tasks tools", "tasks tools create_review"]),
        CommandSpec(name: "raw", aliases: ["call"], usage: ["tasks raw <tool> ['<json>' | -]"], summary: "Call any tool with a JSON object of arguments; prints its JSON answer.", tools: [],
                    notes: "--board and --agent fill in \"board\" and \"agent\" when the JSON leaves them out.",
                    examples: ["tasks raw get_card '{\"board\": \"MyProject\", \"card\": \"PROJ-12\"}'",
                               "tasks raw write_doc --board MyProject '{\"title\": \"Sync plan\", \"text\": \"# Sync plan\\n\\nWhat we sync and when.\"}'",
                               "tasks raw create_review --board MyProject -"],
                    returns: "The tool's own answer (see the tool reference)."),
        CommandSpec(name: "help", usage: ["tasks help [<command>]"], summary: "Show help.", tools: [],
                    examples: ["tasks help update", "tasks update --help"]),
    ]

    public static func spec(_ word: String) -> CommandSpec? {
        all.first { $0.name == word || $0.aliases.contains(word) }
    }
}
