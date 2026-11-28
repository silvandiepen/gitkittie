---
id: MAIL-071
title: "Classification's template terms are matched by `TemplateText`"
date: 2026-11-25
status: proposed
---

# MAIL-071: Classification's template terms are matched by `TemplateText`

**Decision.** Classification's template terms are matched by `TemplateText`: the lower-cased subject and body are searched as canonically decomposed (NFD) UTF-8 bytes (ASCII as is) with `memmem`, and only when the bytes are there does `String.contains` decide. The meaning of a term being "in" the text stays `String.contains` (Characters, canonical equivalence), so no verdict can change; `TemplateTextTests` compares both on every term against awkward text (other normal form, combining marks after a term, Japanese, Greek, CRLF). Every query run per arriving message is pinned by a query-plan test (`IndexQueryPlanTests`), the arrival number included

**Why.** Walking the body Character by Character for each of about 40 terms was 89 % of classification and most of a first sync's client CPU; a byte search says no to almost every term. Skipping a term on bytes is safe because a match's NFD is the term's NFD and NFD never reorders across a Character boundary; claiming a match on bytes alone would not be (a combining mark after the term), so `String.contains` confirms. The `MAX(arrival)` scan showed that one unindexed per-message query is enough to make a first sync quadratic. GKM-040, Performance.md

**Links.** GKM-040
