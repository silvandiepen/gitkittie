---
id: MAIL-058
title: "The cleanup dashboard (Clean Up in the sidebar) is read-only"
date: 2026-11-24
status: proposed
---

# MAIL-058: The cleanup dashboard (Clean Up in the sidebar) is read-only

**Decision.** The cleanup dashboard (Clean Up in the sidebar) is read-only: it reads the index and this device's sync state and shows composition per account and category, noisy senders and lists (volume, share read, last seen), ended offers (an end word followed by a written date, else older than 30 days), recurring digests (three or more issues of one stream with the same subject apart from numbers and dates; the newest is kept), and messages whose attachments reach 5 MB, each with samples that open without being marked read. Batch actions are Archive, Move to Trash and Move to a folder of the account, all through the action journal (MAIL-034) with MAIL-036's folders; there is no permanent delete. For a sender or list, Mute and "Always list under Promotions/Subscriptions" open the sender in the Senders view with that view's rule and its dry-run preview, apply and Undo (MAIL-054); the dashboard makes no rules of its own

**Why.** Classification.md, Cleanup dashboard: read-only first, reversible actions; one rule system, GKM-019's. GKM-021

**Links.** MAIL-034, MAIL-036, MAIL-054, GKM-019, GKM-021
