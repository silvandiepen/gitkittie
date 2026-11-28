---
id: TASKS-08
section: "§ 8"
title: "Phase-1 scope: macOS, shell-out git, GitHub"
date: 2026-07-18
status: accepted
---

# § 8. Phase-1 scope: macOS, shell-out git, GitHub

**Decision.** Phase 1 is **macOS**, git via **shelling out to the system `git` binary** (behind the
`GitEngine` protocol), **GitHub only** for auth (device-flow OAuth + Keychain).

**Context.** The premise ("is a git repo of markdown a pleasant board?") is provable on one platform
with maximum reuse of GitFolder's macOS foundation.

**Rationale.** Prove the schema and sync model cheaply first.

**Status.** Accepted — and **exceeded** in scope: the shipped app owns its checkout, supports
**multiple connected repos and multiple projects per repo**, and ships create/edit/move/reorder/
delete, filters, search, list view, and multi-select. What is still Planned is background interval
sync, a conflict UI, and the fractional rank keys of Decision 6.
