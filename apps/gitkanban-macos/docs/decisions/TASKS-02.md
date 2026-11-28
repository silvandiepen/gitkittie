---
id: TASKS-02
section: "§ 2"
title: "One card = one file"
date: 2026-07-18
status: accepted
---

# § 2. One card = one file

**Decision.** Each card is a single markdown file. Editing a card never touches another card's
bytes.

**Context.** Kanban is a stream of tiny state changes across many devices and writers (human +
agents). A shared `board.json` with an ordered array would be rewritten by every action.

**Rationale.** File-per-card isolates edits: two people working different cards merge cleanly.

**Status.** Accepted.
