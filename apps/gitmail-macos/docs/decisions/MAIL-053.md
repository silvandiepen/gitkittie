---
id: MAIL-053
title: "iOS sync is foreground-first"
date: 2026-11-24
status: proposed
---

# MAIL-053: iOS sync is foreground-first

**Decision.** iOS sync is foreground-first: IMAP IDLE and the sync loop run only while the app is active and stop when it goes to the background (an in-flight sync or SMTP submission finishes under a background task). In the background, `BGAppRefreshTask` checks INBOX of each account for new mail (short, opportunistic) and `BGProcessingTask` does the backlog, indexing and attachment text when the system allows. Notifications come from those checks; no instant push without the optional relay

**Why.** iOS suspends apps and closes their sockets, and the system decides when background tasks run (Architecture.md, Background processing). The outbox's journal and Sent reconciliation (GKM-014) already make a send that is cut off safe. GKM-025

**Links.** GKM-014, GKM-025
