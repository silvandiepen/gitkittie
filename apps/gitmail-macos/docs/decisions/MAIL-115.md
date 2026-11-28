---
id: MAIL-115
title: "**Retention per category** is a policy per account and category"
date: 2026-11-27
status: proposed
---

# MAIL-115: **Retention per category** is a policy per account and category

**Decision.** **Retention per category** is a policy per account and category: Subscriptions (newsletters) 90 days, Promotions 30, Updates 30 by default (Classification.md, Retention), any of 1 week to 1 year, then **Archive** (default) or **Move to Trash**, never a permanent delete (no automatic purge, as the card says). A policy acts on a cleanup group of its own (`CleanupGroupID.Kind.olderThan(category:days:)`: the category's home, `sort_date` older than the age), so its dry run is the cleanup preview (MAIL-060) and **every Clean Up protection holds** (MAIL-059: flagged, in a space, uncertain or under 70% sure, Quarantine, Focused, conversation and account security mail, receipts, a conversation active in the last 14 days, a conversation you wrote in; the thresholds Sil kept in review GKM-042-followups). There is no policy for Focused or Transactions (kept indefinitely), Quarantine (never moved at the provider) or verification codes (account security mail is always protected). A policy has no per-message exclusions: it also acts on mail that arrives later, so a message is kept by flagging it or adding it to a space. Policies and active mode are user data in `metadata/organisation.json` (`OrganisationSettings`), read from the file at every run

**Why.** One preview and one set of protections for everything that moves mail by itself; what Clean Up never suggests, retention never moves. `RetentionTests`, `OrganisationAppTests`. GKM-031

**Links.** MAIL-060, MAIL-059, GKM-042, GKM-031
