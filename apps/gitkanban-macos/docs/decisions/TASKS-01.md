---
id: TASKS-01
section: "§ 1"
title: "TypeScript is the source of truth; Swift mirrors it"
date: 2026-07-18
status: accepted
---

# § 1. TypeScript is the source of truth; Swift mirrors it

**Decision.** The board schema and logic live in `packages/gitkanban-core` (TypeScript, built and
tested). The Swift apps **mirror** this package (via `swift/GitKittieKit`); they do not fork or re-invent
the contract. To change the contract, change it in TypeScript first, then mirror the change in
Swift.

**Context.** GitKanban ships on macOS (shell git) and iOS (git-pont API). Two independently written
parsers would inevitably drift, corrupting boards differently on each platform.

**Rationale.** One reference implementation plus shared fixtures means the parsers cannot diverge.

**Status.** Accepted.
