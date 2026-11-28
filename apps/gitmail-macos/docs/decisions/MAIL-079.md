---
id: MAIL-079
title: "iPhone and iPad storage defaults, decided by Sil (GKM-025)"
date: 2026-11-25
status: proposed
---

# MAIL-079: iPhone and iPad storage defaults, decided by Sil (GKM-025)

**Decision.** iPhone and iPad storage defaults, decided by Sil (GKM-025): the first sync takes the last **14 days**; **every attachment stays at the provider until opened** or pinned (`StorageBudget.attachmentsWhenOpened`, the sync's on-demand threshold at 0; off, attachments over 1 MB wait, as on the Mac); the cache is **250 MB**. A budget saved under the first defaults (no `version`) moves each value that is still a first default (30 days, 500 MB) to the new one and keeps what the person changed; from version 2 every saved value is kept. The cache is trimmed in two steps: attachments through `MailStore.evictCache(toFit:)` (never a pinned part or one that cannot be fetched again, MAIL-064), then the rest of `cache/`; the reader's on-demand cache uses the same budget. Where the mail folder lives on iPhone is asked again in review GKM-042-followups

**Why.** Phones have less space and pay for data (MAIL-068). The cache trim used to walk `cache/blobs` itself and could delete pinned parts and parts no longer at the provider; it no longer touches them. `MobileSessionTests`. GKM-042

**Links.** GKM-025, MAIL-064, GKM-042, MAIL-068
