---
id: MAIL-072
title: "History has a window by received date (`SyncOptions.historyDays`"
date: 2026-11-25
status: proposed
---

# MAIL-072: History has a window by received date (`SyncOptions.historyDays`

**Decision.** History has a window by received date (`SyncOptions.historyDays`; `nil`, the Mac's default, is no window). A folder's history candidates (on its first sync every missing message, afterwards the missing ones at or below its cursor) are sorted with `UID SEARCH SINCE <day>` (INTERNALDATE by calendar day; the day is midnight UTC `historyDays` before today): those received before it stay at the provider (`FolderPlan.older`), the rest are the recent and history imports as before, still within `historyBudgetBytes`. New mail above the cursor always comes in, whatever its date (a message moved in keeps its old received date). A folder with mail left out is not `historyComplete`; the progress counts it (`olderNotDownloaded`) apart from `remaining`, and the status says "older than 30 days not downloaded". A sync searches each folder once and then only for candidates no earlier search sorted (received before a window start stays before every later one). Turning the window off makes the older mail ordinary history: imported newest first within the byte budget, once each (the store's mapping decides). The iPhone and iPad default to 30 days (`StorageBudget.historyDays`; Settings ▸ Storage offers 30 days, 90 days, a year or all, and "Download Older Mail", which turns the window off); the Mac has none by default and offers the same choice in Offline Storage ▸ Download mail from (GKM-060). Searching the server for mail outside the window: MAIL-081..083 (GKM-041)

**Why.** Architecture.md, Storage budgets: a phone's first sync should be today's mail, not years of it, and a count (`recentPerFolder`) or bytes (MAIL-068) say nothing about age. The provider's received date is the one date IMAP can search by, and the sync already compares it by UID, so the window costs one SEARCH per folder, not a fetch of every date. GKM-039

**Links.** GKM-060, MAIL-081, GKM-041, MAIL-068, GKM-039
