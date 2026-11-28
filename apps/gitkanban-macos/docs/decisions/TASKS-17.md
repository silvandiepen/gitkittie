---
id: TASKS-17
section: "§ 17"
title: "The `tasks` command-line tool ships inside the app, sandboxed (GITKITTIE-124)"
date: 2026-11-27
status: accepted
---

# § 17. The `tasks` command-line tool ships inside the app, sandboxed (GITKITTIE-124)

**Context.** Agents without the `tasks` MCP tools were calling the agent server with raw curl
(`POST /mcp` and the bearer token). Sil asked for a command instead.

**Decision.**

- **One tool list.** `MCPTool` and `AgentTools` moved into `TasksAgentTools`, a target without
  dependencies, which both the server (GitKanbanKit) and the CLI (`TasksCLIKit`) import. Each
  command maps to one of those tools; a test checks every command calls a tool the server offers
  with the arguments it requires. `create_review`, `write_doc` and `delete_doc` (base64 uploads,
  compare-and-swap text) go through `tasks raw`.
- **Same door as the bridge.** It reads `AgentAccess/connection.json` (the sandboxed container's
  first, then an unsandboxed build's; the newest wins; `TASKS_CONNECTION` overrides), posts JSON-RPC
  `tools/call` to 127.0.0.1, and on "nothing listens" opens the app by its recorded path through
  Launch Services (not activated) and waits for it, like `tasks-mcp.sh`. `TASKS_NO_WAKE=1` turns
  that off.
- **No `--board` for card commands.** The card's id prefix finds the board: `get_board` on each
  board in the sidebar (its own prefix and its products'), cached in the tool's Caches folder and
  looked at again when a remembered board turns out not to have the card. Boards outside the
  sidebar are never asked, because asking puts them in the sidebar.
- **Who changes a card** comes from `--agent` or `TASKS_AGENT`; there is no default, so a change is
  never recorded under a guessed name.
- **Bundled, not downloaded.** The tool is an XcodeGen `tool` target (`TasksCLI` in `project.yml`)
  copied into `Tasks.app/Contents/Helpers/tasks`, so it always matches the app. Every executable in
  an App Store app has to be sandboxed: it has its own container, `network.client`, an embedded
  Info.plist (bundle id `app.hakobs.gitkanban.tasks`) and a read-only exception for the app's
  `AgentAccess` folder only. Consequence: a sandboxed copy cannot read arbitrary files, so
  `--body-file` and `attach` say to pass the file on standard input (`--body-file - < notes.md`)
  when the read is refused. A `swift build --product tasks` copy is not sandboxed.
- **Install** is a symbolic link the app makes in a folder the person picks in an open panel
  (normally `~/.local/bin`; the sandboxed app may only write where it is pointed). An existing link
  is replaced; any other file named `tasks` is left alone. The app cannot see the shell's PATH, so
  for a folder outside the standard ones it shows the `export PATH=…` line to add.

**Unverified.** The sandboxed helper (temporary exception, opening the app from the sandbox) has
not run with a team-signed build yet; the tests and the demo ran an unsandboxed copy.

**Status.** Accepted.
