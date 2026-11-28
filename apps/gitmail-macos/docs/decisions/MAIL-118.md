---
id: MAIL-118
title: "**The History** (`metadata/organisation-audit.json`, `OrganisationAuditEntry`) lists..."
date: 2026-11-27
status: proposed
---

# MAIL-118: **The History** (`metadata/organisation-audit.json`, `OrganisationAuditEntry`) lists...

**Decision.** **The History** (`metadata/organisation-audit.json`, `OrganisationAuditEntry`) lists every run of active organisation, newest first: operation id, time, device, account, what made it (a policy with its category and age, or a sender rule by id), whether you confirmed it or it ran after a sync, the action, the count, its journal batch, and each move as the store's message id and the two folder names. **No mail content**: no subject, address or text (`RetentionTests` checks the file). The last 1,000 entries are kept. **Undo** is offered on the device that made the step (its message ids and journal are its own), once: the journal batch is undone while the journal has it (MAIL-037, seven days), after that each recorded move goes back for every message still where it was moved to. Undoing a policy's step turns that policy off and says so, or its next run would move the same mail again; flag or space what you want kept, then turn it on from its dry run

**Why.** Classification.md, Retention: "audit action reason, time, account, operation ID and undo status without full mail content". Keeping the moves makes Undo work after the journal lets go of the batch; proven against GreenMail after pruning the journal. GKM-031

**Links.** MAIL-037, GKM-031
