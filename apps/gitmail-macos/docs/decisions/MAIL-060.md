---
id: MAIL-060
title: "A preview is the exact scope"
date: 2026-11-24
status: proposed
---

# MAIL-060: A preview is the exact scope

**Decision.** A preview is the exact scope: each message's journal changes plus what it saw (effective folders, flagged, answered). Run is one `MailStore` actor step: it makes the preview again from the latest state, refuses (and runs nothing) when any message to run left the group, became protected or skipped, or has other folders, flags or changes, then writes all rows as one journal batch and checks every message took. Messages that joined the group after the preview are not run, because you never saw them. Read state is not compared

**Why.** No sync write can land between check and write; a refusal shows the differences and a fresh preview. GKM-021

**Links.** GKM-021
