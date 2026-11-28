---
id: TASKS-05
section: "§ 5"
title: "Config inheritance: lanes replace, vocabularies merge"
date: 2026-07-18
status: accepted
---

# § 5. Config inheritance: lanes replace, vocabularies merge

**Decision.** Effective config = root config overlaid with project config. A non-empty project
`lanes` list **replaces** the root lanes (custom workflow); `users`/`priorities`/`types`/`epics`/
`tags` **merge** (project entries extend root; same `id` → project wins). Implemented as
`resolveEffectiveConfig(root, project)`.

**Context.** The `Tasks/` contract defines configuration as README frontmatter at root and per
project, and the app consumes it as data — reading it to render and writing it via project
create/settings.

**Rationale.** Lanes are structural (replace); vocabularies are additive dimensions (merge).

**Status.** Accepted.
