---
id: MAIL-020
title: "The IMAP mapping (mailbox + UIDVALIDITY + UID → local id) lives in `<Application..."
date: 2026-11-24
status: proposed
---

# MAIL-020: The IMAP mapping (mailbox + UIDVALIDITY + UID → local id) lives in `<Application...

**Decision.** The IMAP mapping (mailbox + UIDVALIDITY + UID → local id) lives in `<Application Support>/Mail/state/<account-id>/sync.sqlite`, not in the folder

**Why.** It is a device's position at the provider, like the cursors (MAIL-013); losing it costs a reconciliation pass by Message-ID and fingerprint, not mail. GKM-005

**Links.** MAIL-013, GKM-005
