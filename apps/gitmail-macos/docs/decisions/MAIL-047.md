---
id: MAIL-047
title: "While a history import continues pass after pass, flags are checked at most every two..."
date: 2026-11-24
status: proposed
---

# MAIL-047: While a history import continues pass after pass, flags are checked at most every two...

**Decision.** While a history import continues pass after pass, flags are checked at most every two minutes (`flagCheckInterval`) and once when the history is complete; every pass still checks for new mail first. Body fetches take up to 100 messages (8 MB)

**Why.** Re-reading every stored message's flags per 500-message slice was quadratic in the mailbox size; a quarter of the round trips on a slow link. Performance.md. GKM-035

**Links.** GKM-035
