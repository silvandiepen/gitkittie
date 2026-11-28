---
id: TASKS-10
section: "§ 10"
title: "`GitEngine` protocol boundary; shell-git on macOS"
date: 2026-07-18
status: accepted
---

# § 10. `GitEngine` protocol boundary; shell-git on macOS

**Decision.** The macOS app calls git only through a `GitEngine` protocol
(`clone / pullRebase / commit / push / status / fileHistory`), implemented by `ShellGitEngine`
(subprocess `git`).

**Context.** iOS has no shell — the biggest platform delta. The protocol keeps the transport
swappable.

**Rationale.** The protocol boundary lets macOS move fast on shell-git while keeping the board UI
transport-agnostic.

**Status.** Accepted (protocol + `ShellGitEngine` exist and are used by the app). NB: iOS did **not**
implement `Libgit2Engine` behind this protocol — it ships over a REST API via git-pont using
GitKittie's `RemoteBoardStore`/`BoardFileSource` instead (see Decision 12 and the iOS app).
