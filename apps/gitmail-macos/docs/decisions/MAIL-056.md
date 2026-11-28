---
id: MAIL-056
title: "Unsubscribe is decided from the stored headers of a sender's newest message, never by..."
date: 2026-11-24
status: proposed
---

# MAIL-056: Unsubscribe is decided from the stored headers of a sender's newest message, never by...

**Decision.** Unsubscribe is decided from the stored headers of a sender's newest message, never by fetching: offered only when its risk is none, no reason doubts the sender (failed trusted authentication, display-name spoof, lookalike sender or link), it has a List-Unsubscribe and either a List-ID or `List-Unsubscribe-Post: List-Unsubscribe=One-Click`. Suspicious mail gets Report as Junk (a local spam correction plus a move to the account's junk folder through the journal) and Mute instead. Order: RFC 8058 one-click (only with that exact Post value and an HTTPS URL), then `mailto:`, then a manual page. Endpoints must be HTTPS on 443 with a named, public, non-IDN, non-lookalike host and no user-info. One-click is one POST of `List-Unsubscribe=One-Click` after you approve that URL; the headers are re-read first and nothing is sent if it changed. The session is ephemeral with no cookie storage, cache or credential storage, answers no authentication challenge, and follows no redirect except a 307/308 to the same host and port, at most twice, each re-checked. `mailto:` keeps only address, subject and body, is shown before sending from the address the list wrote to, and goes through the outbox. A manual page opens in the browser only after a warning. RFC 8058's DKIM requirement cannot be checked yet (no verified Authentication-Results); the list-context and sender checks stand in for it

**Why.** ThreatModel §9: never confirm an address to a spammer, never contact an endpoint while scanning, never follow a list to somewhere else with your cookies. GKM-020

**Links.** GKM-020
