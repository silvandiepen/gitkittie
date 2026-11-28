---
id: TASKS-12
section: "§ 12"
title: "iOS transport superseded: git-pont REST API, not libgit2"
date: 2026-07-18
status: accepted
---

# § 12. iOS transport superseded: git-pont REST API, not libgit2

**Decision.** The iOS app talks to a hosted git provider's REST API through **git-pont** (no local
clone), reusing GitKittie's `RemoteBoardStore`/`BoardFileSource` for parsing. It does **not** use an
embedded `Libgit2Engine`.

**Context.** The plan originally gated iOS on an embedded-libgit2 `GitEngine`. In practice the iOS
app shipped read/write over provider APIs (GitHub + GitLab + self-hosted) with a personal-access
token, which was simpler and already works.

**Rationale.** API-first removes the native-dependency risk and reaches a working iOS board without
building/maintaining libgit2. An embedded offline mode remains a possible later addition, not a
gate.

**Status.** Accepted for iOS. The libgit2 path is **superseded / deferred**. (This is a macOS-app
doc; details live in the iOS app's `docs/`.)
