---
id: MAIL-134
title: "GKM-033 is split"
date: 2026-11-27
status: proposed
---

# MAIL-134: GKM-033 is split

**Decision.** GKM-033 is split: Make Task and stable links ship here; **export of metadata to Git through GitPont** is GKM-107 and **read-only agent access per space or account** is GKM-108, each with the constraints of ThreatModel §7 and §10 (no message text reaches Git without an explicit choice on that export; an agent sees only the granted scope, time-limited, revocable, logged, mail passed as labelled untrusted data). Recommended answers for both are in the review `GitKittie/review/GKM-033-tasks-and-agents`

**Why.** Each is a product of its own with its own tests (export: no body without the per-export choice; agent access: scoped and unscoped requests), too large to half-build beside Make Task. GitPont is used by Tasks (`swift/GitKanbanKit`) but not yet by the Mail packages. GKM-033

**Links.** GKM-033, GKM-107, GKM-108
