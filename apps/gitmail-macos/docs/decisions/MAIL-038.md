---
id: MAIL-038
title: "Classification is read-only and derived"
date: 2026-11-24
status: proposed
---

# MAIL-038: Classification is read-only and derived

**Decision.** Classification is read-only and derived: every message is classified when it is stored, and its verdict (purpose, risk, urgency, home view, reason codes, evidence, rule-set version) lives in `index.sqlite` (schema step `message_classes`, plus `correspondents` and `authenticated_domains` learned from the mail). A new rule set or a rebuilt index reclassifies in the background; a message without a verdict counts as Focused. Organisation domains come from the bundled Public Suffix List (MPL-2.0, unmodified; the reserved `example.*` domains count as suffixes). Authentication-Results count only from `authserv-id`s verified per provider, none yet; a domain becomes a trusted sender after passing trusted authentication on two messages a week apart (or once, if you wrote to someone there), never if it imitates one already trusted, and never a bare public suffix

**Why.** Verdicts can always be made again from the folder, so they belong with the index; nothing is written to the mail folder, the sync state or the provider (MAIL-007, ThreatModel §3, §11). GKM-017

**Links.** MAIL-007, GKM-017
