---
id: TASKS-09
section: "§ 9"
title: "GitKanban lives in the GitKittie monorepo, sharing one git/board package"
date: 2026-08-02
status: accepted
---

# § 9. GitKanban lives in the GitKittie monorepo, sharing one git/board package

**Decision.** GitKanban is built inside the GitKittie monorepo alongside GitFolder, not as a forked
repo. Both apps depend on the shared `swift/GitKittieKit` Swift package (git engine, board parsing,
keychain, OAuth, repos service); board logic depends on `packages/gitkanban-core`. Apps never import
each other.

**Context.** An earlier draft recommended a standalone repo; that was reversed — the git engine and
board parsing are genuinely shared code.

**Rationale.** One repo means the two apps can't drift and one fix benefits both, while each still
ships to the App Store independently.

**Status.** Accepted.
