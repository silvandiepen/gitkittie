---
id: MAIL-023
title: "Sent copies follow a per-account policy"
date: 2026-11-24
status: proposed
---

# MAIL-023: Sent copies follow a per-account policy

**Decision.** Sent copies follow a per-account policy: `providerFiles` (Gmail) never appends; `append` (generic IMAP) appends only after a Message-ID search finds none; `detect` (iCloud, until the GKM-004 run records what iCloud does) waits two minutes for the provider's copy before appending

**Why.** Search-before-append makes the append idempotent across crashes; `detect` avoids guessing a provider's behaviour. GKM-014

**Links.** GKM-004, GKM-014
