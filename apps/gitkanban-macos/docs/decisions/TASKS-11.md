---
id: TASKS-11
section: "§ 11"
title: "YAML frontmatter via Yams (Swift), `yaml` (TS)"
date: 2026-07-18
status: accepted
---

# § 11. YAML frontmatter via Yams (Swift), `yaml` (TS)

**Decision.** The TS core parses/serializes frontmatter with the `yaml` package; the Swift board
parsing in `swift/GitKittieKit` uses **Yams**.

**Context.** Frontmatter round-trip fidelity across two languages is the correctness crux
(Decision 4).

**Rationale.** Established YAML libraries on each side, exercised against shared fixtures, keep the
parsers aligned.

**Status.** Accepted for the **read** path (GitKittie's `BoardStore`/`BoardMarkdown` use Yams). The
macOS app's **write** path currently bypasses Yams (hand-rolled frontmatter composition in
`AppModel`); moving writes onto Yams/`BoardMarkdown` is tracked on the board (see Decision 4).
