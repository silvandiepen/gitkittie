---
id: MAIL-041
title: "Only unread mail in Focused counts on the Dock badge and may notify"
date: 2026-11-24
status: proposed
---

# MAIL-041: Only unread mail in Focused counts on the Dock badge and may notify

**Decision.** Only unread mail in Focused counts on the Dock badge and may notify; every view shows its own unread count. A notification is for mail that arrives while the app runs and is under a day old (never history or imports), at most three at once, else one summary; it carries sender and subject only. Per account: Focused (default) or Off (also off the badge); per list: like Focused, Always (never from Quarantine) or Never. Permission is asked the first time there is something to say. Settings live in `preferences/notifications.json` on this device until GKM-026

**Why.** Promotions, newsletters and routine updates are silent (Classification.md, Notifications); asking at launch would be noise too. GKM-018

**Links.** GKM-026, GKM-018
