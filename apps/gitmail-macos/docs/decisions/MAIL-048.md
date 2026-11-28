---
id: MAIL-048
title: "IMAP response lines up to 16 MiB are accepted (swift-nio-imap's default is 8 KB)"
date: 2026-11-24
status: proposed
---

# MAIL-048: IMAP response lines up to 16 MiB are accepted (swift-nio-imap's default is 8 KB)

**Decision.** IMAP response lines up to 16 MiB are accepted (swift-nio-imap's default is 8 KB); message bodies stay streamed and limited separately

**Why.** `UID SEARCH ALL` on a folder of about 1,900 messages already exceeds 8 KB, which closed the connection on every listing, so large mailboxes never synced. 16 MiB bounds what a hostile server can make us buffer. GKM-035

**Links.** GKM-035
