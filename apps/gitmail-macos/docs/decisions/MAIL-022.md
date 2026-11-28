---
id: MAIL-022
title: "The outbox journal lives in device state (`<Application Support>/Mail/state/outbox/`),..."
date: 2026-11-24
status: proposed
---

# MAIL-022: The outbox journal lives in device state (`<Application Support>/Mail/state/outbox/`),...

**Decision.** The outbox journal lives in device state (`<Application Support>/Mail/state/outbox/`), one folder per send with the exact bytes and the entry. Only a `notSent` outcome is retried automatically; an `uncertain` send is reconciled by Message-ID and otherwise waits for the person, and Send Again checks once more first, with the same Message-ID

**Why.** A send is one device's commitment, never synced (GKM-028 coordinates devices). The only safe automatic resend is one the server provably did not take. GKM-014

**Links.** GKM-028, GKM-014
