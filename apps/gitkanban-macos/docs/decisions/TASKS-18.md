---
id: TASKS-18
section: "§ 18"
title: "One agent guide, printed by `tasks guide` and served as `get_agent_guide` (GITKITTIE-124)"
date: 2026-11-27
status: accepted
---

# § 18. One agent guide, printed by `tasks guide` and served as `get_agent_guide` (GITKITTIE-124)

**Context.** The prompt in Agent Access had grown into a half-manual that still left agents guessing
(heartbeats, reviews, what the app enforces versus what the contract asks). Sil asked for one prompt
that gives an agent the full docs.

**Decision.**

- **One text, two doors.** `AgentGuide.text()` in `TasksAgentTools` is the manual. `tasks guide`
  prints it (offline: no app needed) and the agent server's new `get_agent_guide` tool returns it.
  `--board <B>` / `"board"` append that board's rules from `get_board_rules`, formatted by the same
  function, so both doors give the same text. `--json` prints it as one JSON string.
- **Prose in Markdown, reference generated.** The prose is `Sources/TasksAgentTools/AgentGuide.md`,
  compiled in with SwiftPM's `.embedInCode` (the CLI ships alone in `Contents/Helpers`, so a
  resource bundle beside it would be one more thing to get wrong; a missing bundle would also be a
  crash in `Bundle.module`). The command, tool, exit-code and environment sections are generated
  from `CommandTable` and `AgentTools.all`. For that, the CLI's command table (`CommandSpec`,
  `OptionSpec`, environment, `ExitStatus`) moved from `TasksCLIKit` into `TasksAgentTools`: the app
  serves the guide too and does not link the CLI. `CLIError` takes its exit codes and kinds from
  `ExitStatus`, so the table the guide prints is the one the CLI exits with.
- **Can't drift:** tests check that the guide has every command (usage, options, examples), every
  tool (every argument), every exit code and variable; that every command line in it (the table's
  examples and the prose's `sh` blocks) parses; and that the CLI and the MCP tool return the same
  text, with and without a board.
- **The guide does not hard-code one board.** It tells the agent to read the board's rules first and
  that they win; lanes and fields are described as "the standard contract".
- **The prompt is short:** what Tasks is, and "run `tasks guide` (or call `get_agent_guide`) first".
  Agent Access keeps Copy Prompt and adds Copy Full Guide for agents with neither.
- **Heartbeat.** The contract asks owners to renew `last_heartbeat_at` / `claim_expires_at`; there was
  no clean way. Claiming your own card again now renews the lease and keeps `picked_up_at`
  (activity "renewed the claim until …", commit `chore(tasks): heartbeat <id>`); the guide says so.

**Unverified.** `.embedInCode` is exercised by `swift build` / `swift test`; the Xcode builds of the
apps (which compile `TasksAgentTools` through the package) are left to CI.

**Status.** Accepted.
