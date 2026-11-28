---
id: TASKS-06
section: "§ 6"
title: "Ordering within a lane — fractional rank keys (core) vs integer `order` (app today)"
date: 2026-07-18
status: accepted
---

# § 6. Ordering within a lane — fractional rank keys (core) vs integer `order` (app today)

**Decision (target).** Position within a lane is a fractional / lexicographic rank key stored as
`order` (wrappers over `fractional-indexing`); inserting between two cards mints one new key and
rewrites only the moved card. Boards without rank keys fall back to priority + `created_at` + `id`.

**Context.** "Between these two cards" is the classic distributed-order problem; integer positions
force a rewrite of every card below an insert and conflict when two clients insert nearby.

**Rationale.** Rank keys make an insert O(1) writes and O(1) diff. The fallback sort handles boards
(like the audit/task boards) that carry no `order`.

**Status.** Core: **Accepted and implemented** (`rank.ts`). App: **not yet adopted** — the macOS
app currently writes an **integer `order = index + 1`** and rewrites the affected lane on reorder.
This works but reintroduces the neighbour-churn the rank keys were meant to avoid. Adopting the
fractional key path in the app is tracked on the board.
