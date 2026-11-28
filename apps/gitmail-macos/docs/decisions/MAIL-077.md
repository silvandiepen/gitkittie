---
id: MAIL-077
title: "An account with neither `\\Archive` nor `\\All` gets an \"Archive\" folder, created..."
date: 2026-11-25
status: accepted
---

# MAIL-077: An account with neither `\Archive` nor `\All` gets an "Archive" folder, created...

**Decision.** An account with neither `\Archive` nor `\All` gets an "Archive" folder, created silently the first time something is archived (MAIL-036 as built)

**Why.** Decided by Sil (GKM-015). `MailActionsTests.testAnArchiveReachesTheProviderAndItsUndoBringsItBack` now checks the test account has no Archive folder before, and that the archive creates it at the provider. GKM-042

**Links.** MAIL-036, GKM-015, GKM-042
