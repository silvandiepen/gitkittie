---
id: MAIL-130
title: "**Archive sync is not built now"
date: 2026-11-27
status: proposed
---

# MAIL-130: **Archive sync is not built now

**Decision.** **Archive sync is not built now; later, and then as scheduled full archives to a folder the person picks**, not as an incremental encrypted repository. Recommendation and reasons in `ArchiveSync.md`

**Why.** With one shared iCloud Drive mail folder (Sil, 2026-11-26; GKM-026 design) multi-device is solved by the folder, so archive sync would only add a second, versioned copy outside the live folder, which manual archives (MAIL-128) and Time Machine already give. Scheduled archives reuse this format and its tests; an incremental repository needs its own index, garbage collection and concurrent-writer rules, too much for a P3 before GKM-026 is built. GKM-032

**Links.** GKM-026, MAIL-128, GKM-032
