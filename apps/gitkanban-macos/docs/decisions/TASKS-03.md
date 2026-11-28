---
id: TASKS-03
section: "§ 3"
title: "A column is a lane folder; a card's `status` must match its folder"
date: 2026-07-18
status: accepted
---

# § 3. A column is a lane folder; a card's `status` must match its folder

**Decision.** A card's column is a **folder** (`1. To do/`, `2. In Progress/`, …), and the card's
`status` field must match its lane folder. **Moving a card moves its file into the destination lane
folder and updates `status`** in the same action, so folder and frontmatter always agree.

**Context.** An earlier plan draft had the column be *only* a `status` field, with the file staying
put ("moving a card does not move the file"). The live `Tasks/` contract, however, makes lane
folders the primary, human-browsable view and requires `status` to match — and the shipped app
follows that contract. So the app **does** move the file on a lane change.

**Rationale.** Folder-per-lane keeps the repo readable to humans and tools browsing the tree, and
the card's stable `id`/filename preserves `git log --follow` across the move. The `status` field
keeps the value machine-readable and lets `groupIntoColumns` place cards without walking the tree.

**Status.** Accepted (revised from the earlier "field, not folder" draft to match the canonical
contract and the shipped app).
