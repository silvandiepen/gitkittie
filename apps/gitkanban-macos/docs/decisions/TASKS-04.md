---
id: TASKS-04
section: "§ 4"
title: "Additive, lenient frontmatter — unknown keys are preserved"
date: 2026-07-18
status: accepted
---

# § 4. Additive, lenient frontmatter — unknown keys are preserved

**Decision.** Parse/serialize should round-trip **every** frontmatter (and config) key verbatim,
including keys the app does not model. A read-then-write of an unchanged card should produce a zero
diff.

**Context.** Boards are written by external tools — sills audits, CI, scripts, agents — that add
fields GitKanban has never heard of. The canonical card carries a large lifecycle vocabulary
(`picked_up_by`, `reviewer`, `testing_owner`, …) beyond the fields the board UI reads.

**Rationale.** Preserving unknown keys means the app is one writer among many without being the
schema authority, keeping agents' diffs readable.

**Status.** Accepted in principle and honoured by the core (TS) parser. **At risk in the app:** the
macOS app currently composes frontmatter with hand-rolled string editing in `AppModel`
(`composeFrontmatter`/`setFrontmatterKey`/`composeCard`) rather than round-tripping through
`BoardMarkdown`/Yams. Routing writes through the shared layer and adding a zero-diff round-trip test
is tracked on the board.
