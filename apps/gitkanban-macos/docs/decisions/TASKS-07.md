---
id: TASKS-07
section: "§ 7"
title: "Body-section field source for legacy boards"
date: 2026-07-18
status: accepted
---

# § 7. Body-section field source for legacy boards

**Decision.** Support two field sources: `frontmatter` (native GitKanban format) and `body-section`
(read `**Label:** value` lines from a named markdown section — the legacy `audit/tasks` format).
The source is set in config and honoured by `resolveCardFields`.

**Context.** The existing audit boards store `State`/`Assignee`/`Branch·PR` in a `## Status` body
block. Hundreds of such files exist.

**Rationale.** GitKanban can open today's boards without rewriting files.

**Status.** Accepted. Core: implemented; the app auto-detects the legacy format.
