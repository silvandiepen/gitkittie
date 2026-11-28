import Foundation

// The tools the Tasks app's agent server offers (`MCPServer.swift` in GitKanbanKit) and what
// agents are told about them. A target of its own, with no dependencies, so the `tasks`
// command-line tool shares this one list with the server instead of keeping a copy.

/// One tool an agent can call.
public struct MCPTool: Sendable {
    public let name: String
    public let description: String
    /// A JSON Schema object for the arguments, as JSON text.
    public let inputSchema: String
    public init(name: String, description: String, inputSchema: String) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// The tools the agent server offers, and how to use them.
public enum AgentTools {
    /// The short text for an agent's instructions file (CLAUDE.md, AGENTS.md): what Tasks is, and
    /// to read the guide first. Everything else is in the guide (`AgentGuide`), which the agent
    /// gets from `tasks guide` or `get_agent_guide`, so this never goes out of date.
    public static let prompt = """
    ## Tasks: the shared task board

    My work is tracked in **Tasks** (GitKittie Tasks), a Kanban board app whose boards are Markdown \
    cards in git repositories; every session reads it to see where the last one left off and keeps \
    it current.

    **Before anything else, run `tasks guide` (or call the `get_agent_guide` tool of the `tasks` MCP \
    server) and follow it.** It is the complete manual: how to reach the boards, the start-of-work \
    routine, the card lifecycle, reviews, and every command and tool. If you have neither the \
    command nor the tools, say so and ask me for the full guide.
    """

    public static let instructions = """
    This is the person's task board, served by the Tasks app (GitKittie Tasks). Call get_agent_guide first and \
    follow it: it is the complete manual for working on the boards. Use these tools for everything on the board instead of \
    reading or writing card files in a repository. Start with list_boards. Before your first change on a board, \
    read get_board_rules once: it is the board's contract (fields, lanes, lifecycle) and it wins over anything \
    written here. Claim a card with claim_card before you implement it. Keep the card current while you work with \
    update_card (fields, an activity entry, a move to another lane). Every change is written and committed at once; \
    a call that returns without error has landed. Never set read_at or read_by.
    """

    private static let board = #""board": {"type": "string", "description": "The board, as list_boards names it (e.g. tasks/GitKittie), or just its name when that is unambiguous."}"#
    private static let card = #""card": {"type": "string", "description": "The card's id (e.g. GITKITTIE-021) or its file name."}"#
    private static let agent = #""agent": {"type": "string", "description": "Your canonical agent handle (e.g. hermio), recorded on the card."}"#
    private static let action = #"{"type": "object", "properties": {"move": {"type": "string", "description": "Card id on this board to move. Default: the request's card (required on an item or check)."}, "to": {"type": "string", "description": "Lane id, name or status."}, "comment": {"type": "boolean", "description": "Copy the reviewer's comments into the card's activity log."}, "assign": {"type": "string", "description": "Set the card's assignee to this board user."}}, "required": ["to"]}"#
    private static func actions(_ whose: String) -> String {
        ["on_accept", "on_changes", "on_reject"].map { key in
            #""\#(key)": {"description": "What happens to cards when \#(whose) is \#(key == "on_accept" ? "accepted" : key == "on_changes" ? "sent back with changes requested" : "rejected"): one action or a list.", "oneOf": [\#(action), {"type": "array", "items": \#(action)}]}"#
        }.joined(separator: ", ")
    }
    private static let fields = #""fields": {"type": "object", "description": "Top-level frontmatter keys to set, e.g. {\"priority\": \"P1\", \"blocked\": true, \"commits\": [\"abc123\"], \"reviewer\": null}. Values: string, number, boolean, null, or a list of strings. Other keys are left as they are.", "additionalProperties": true}"#

    public static let all: [MCPTool] = [
        MCPTool(name: "get_agent_guide", description: "The complete manual for agents working on these boards (the same text as `tasks guide`): the start-of-work routine, the card lifecycle, reviews, docs, every tool and command, and what to do when something fails. Read it once before anything else. With \"board\", that board's rules are appended.",
                inputSchema: #"{"type": "object", "properties": {"board": {"type": "string", "description": "Optional: a board whose rules (get_board_rules) to append."}}}"#),
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
        MCPTool(name: "list_reviews", description: "The board's review requests: the reviewer's decisions on files and browser checks, answers to questions, and comments. state: to_handle (default; entries the reviewer decided or answered that you have not acted on yet), pending (still waiting for the reviewer), all. An answered question gives \"answer\" (the chosen option ids), \"answer_labels\" and, when the reviewer wrote one, \"answer_other\". A browser check gives its \"results\" per size and a \"failed\" list of the lines answered fail or with a note (screenshots: get_review_file). Each request gives \"for\" (who decides; empty = anyone), \"outcome\" (accept, changes, reject, or null until every file and check is decided) and \"actions_run\": what the app already did to cards on the decision. Never move a card an action already moved; act on the feedback.",
                inputSchema: #"{"type": "object", "properties": {\#(board), "state": {"type": "string", "enum": ["to_handle", "pending", "all"]}, "card": {"type": "string", "description": "Only requests of this card."}, "for": {"type": "string", "description": "Only requests this board user decides (theirs and the ones for anyone)."}}, "required": ["board"]}"#),
        MCPTool(name: "create_review", description: "Ask the reviewer to judge files (images, models, audio, video), to check web pages in a browser, or to answer questions: writes the files and the request. Use \"questions\" for a decision between options (single choice with select one, several with select many; other: true lets the reviewer write an answer of their own); never send options as files to approve. Use \"checks\" for a page to look at: a url the reviewer's phone can open, sizes, and a checklist answered pass or fail per size. Give \"title\" for a new request, or \"request\" to add entries to an existing one (a redo: set \"revises\" to the item or check it replaces). Ids are unique across a request's items, questions and checks. \"on_accept\" / \"on_changes\" / \"on_reject\" say where the card goes when the request is decided (the app moves it; you don't): e.g. {\"to\": \"testing\"} and {\"to\": \"in-progress\", \"comment\": true}. \"for\" puts it on board users (who asked for the work); \"due\" is a day. \"notify\" sets how loudly it is announced (urgent, normal, silent). Large files can instead be committed in the board's repository under <board>/review/<request>/.",
                inputSchema: #"{"type": "object", "properties": {\#(board), "request": {"type": "string", "description": "Id of an existing request to add items or questions to."}, "card": {"type": "string", "description": "The card the request belongs to."}, "title": {"type": "string"}, "question": {"type": "string", "description": "What the reviewer should do, in one line."}, "notify": {"type": "string", "enum": ["urgent", "normal", "silent"], "description": "How loudly the request is announced on the reviewer's devices. urgent: time-sensitive, breaks through Focus; only when work is blocked on the answer. normal (default): an ordinary notification. silent: no notification, only the badge and the Reviews list. With \"request\" alone it changes an existing request's level."}, "notes": {"type": "string"}, "for": {"description": "Board user ids who decide (one id or a list). Absent: anyone on the board. Routing, not privacy.", "oneOf": [{"type": "string"}, {"type": "array", "items": {"type": "string"}}]}, "due": {"type": "string", "description": "The day it is due, YYYY-MM-DD."}, \#(actions("the request")), "items": {"type": "array", "description": "Files to judge.", "items": {"type": "object", "properties": {"id": {"type": "string"}, "file_name": {"type": "string"}, "content_base64": {"type": "string"}, "preview_file_name": {"type": "string", "description": "A PNG shown for a model or video."}, "preview_base64": {"type": "string"}, "kind": {"type": "string", "enum": ["image", "model", "audio", "animation", "video", "other"]}, "group": {"type": "string", "description": "Items in one group are shown side by side."}, "pick_one": {"type": "boolean", "description": "The reviewer chooses one item of the group."}, "note": {"type": "string"}, "revises": {"type": "string"}, \#(actions("this file"))}, "required": ["id", "file_name", "content_base64"]}}, "checks": {"type": "array", "description": "Web pages to check in a browser, at sizes, against a checklist.", "items": {"type": "object", "properties": {"id": {"type": "string"}, "url": {"type": "string", "description": "An address the reviewer's devices can open (a preview deploy or a tailnet host, not localhost)."}, "title": {"type": "string"}, "note": {"type": "string"}, "sizes": {"type": "array", "description": "Presets (phone-small, phone, phone-large, tablet, tablet-landscape, laptop, desktop, wide), \"WIDTHxHEIGHT\", or {id, label, width, height, ua: mobile|desktop|default}. Absent: one size, whatever the reviewer opens it in.", "items": {"oneOf": [{"type": "string"}, {"type": "object", "properties": {"id": {"type": "string"}, "label": {"type": "string"}, "width": {"type": "integer"}, "height": {"type": "integer"}, "ua": {"type": "string", "enum": ["mobile", "desktop", "default"]}}}]}}, "appearance": {"type": "array", "items": {"type": "string", "enum": ["light", "dark"]}, "description": "Check each size in light and/or dark."}, "checklist": {"type": "array", "description": "Statements answered pass or fail per size.", "items": {"oneOf": [{"type": "string"}, {"type": "object", "properties": {"id": {"type": "string"}, "text": {"type": "string"}}, "required": ["text"]}]}}, "revises": {"type": "string", "description": "The check this one redoes."}, \#(actions("this check"))}, "required": ["id", "url", "checklist"]}}, "questions": {"type": "array", "description": "Questions to answer, shown as a form.", "items": {"type": "object", "properties": {"id": {"type": "string"}, "question": {"type": "string", "description": "The question, in one line."}, "detail": {"type": "string", "description": "Markdown: background the reviewer needs."}, "select": {"type": "string", "enum": ["one", "many"], "description": "one (default): a single answer. many: any number of options."}, "other": {"type": "boolean", "description": "Let the reviewer write an answer of their own. Default false."}, "options": {"type": "array", "items": {"type": "object", "properties": {"id": {"type": "string"}, "label": {"type": "string", "description": "The option, in a few words."}, "detail": {"type": "string", "description": "Markdown: what choosing it means and what it costs."}}, "required": ["id", "label"]}}}, "required": ["id", "question", "options"]}}, \#(agent)}, "required": ["board", "agent"]}"#),
        MCPTool(name: "handle_review_item", description: "Record that you acted on a decided review item (shipped the approved file, dropped the rejected one, submitted the redo), a decided browser check, or an answered question (pass the check's or question's id as item). An answer is fixed once handled. When that leaves the request with nothing pending and nothing to handle, the request is finished and its folder is removed, unless keep is true.",
                inputSchema: #"{"type": "object", "properties": {\#(board), "request": {"type": "string"}, "item": {"type": "string", "description": "The item's, check's or question's id."}, "shipped_to": {"type": "string", "description": "Where an approved file now lives."}, "keep": {"type": "boolean", "description": "Leave a finished request in place. Default false."}}, "required": ["board", "request", "item"]}"#),
        MCPTool(name: "get_review_file", description: "One file of a review request as base64: a browser check's screenshot (results/<check>-<size>.png, as list_reviews names it), a marked-up image from a comment, or an asset. For an agent without a clone of the board.",
                inputSchema: #"{"type": "object", "properties": {\#(board), "request": {"type": "string"}, "path": {"type": "string", "description": "Relative to the request's folder, e.g. results/onboarding-page-phone.png."}}, "required": ["board", "request", "path"]}"#),
        MCPTool(name: "close_review", description: "Remove a finished review request and its files. Refused while items or questions are waiting for the reviewer, or decided or answered but not handled, unless force is true.",
                inputSchema: #"{"type": "object", "properties": {\#(board), "request": {"type": "string"}, "force": {"type": "boolean"}}, "required": ["board", "request"]}"#),
        MCPTool(name: "wait_for_reviews", description: "Wait until the reviewer has decided or answered something you have not handled yet, then return it (as list_reviews with state to_handle). Returns an empty list when the time is up; call again to keep listening.",
                inputSchema: #"{"type": "object", "properties": {\#(board), "card": {"type": "string"}, "timeout_seconds": {"type": "number", "description": "How long to wait, up to 240. Default 120."}}, "required": ["board"]}"#),
        MCPTool(name: "list_docs", description: "The board's documentation pages: README.md (the text under its configuration) and the Markdown files in docs/. Plans, specs and decisions about the project live here.",
                inputSchema: #"{"type": "object", "properties": {\#(board)}, "required": ["board"]}"#),
        MCPTool(name: "get_doc", description: "One documentation page's full text.",
                inputSchema: #"{"type": "object", "properties": {\#(board), "path": {"type": "string", "description": "As list_docs gives it, e.g. docs/plan.md or README.md."}}, "required": ["board", "path"]}"#),
        MCPTool(name: "search_docs", description: "Search the board's documentation pages. Returns the lines that contain every word of the query, with their page and heading.",
                inputSchema: #"{"type": "object", "properties": {\#(board), "query": {"type": "string"}}, "required": ["board", "query"]}"#),
        MCPTool(name: "write_doc", description: "Create a documentation page (give \"title\"), or replace an existing one (give \"path\" and, as \"replaces\", the exact text you read with get_doc; refused when the page changed since). Prefer adding to a page or writing a new one over rewriting what the owner wrote.",
                inputSchema: #"{"type": "object", "properties": {\#(board), "path": {"type": "string"}, "title": {"type": "string"}, "text": {"type": "string", "description": "The page's whole Markdown text."}, "replaces": {"type": "string"}, "agent": {"type": "string"}}, "required": ["board", "text"]}"#),
        MCPTool(name: "delete_doc", description: "Delete a documentation page in docs/.",
                inputSchema: #"{"type": "object", "properties": {\#(board), "path": {"type": "string"}}, "required": ["board", "path"]}"#),
        MCPTool(name: "attach_file", description: "Attach a file (a screenshot) to a card.",
                inputSchema: #"{"type": "object", "properties": {\#(board), \#(card), "file_name": {"type": "string"}, "content_base64": {"type": "string"}}, "required": ["board", "card", "file_name", "content_base64"]}"#),
    ]
}
