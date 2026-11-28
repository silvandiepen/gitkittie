---
id: MAIL-116
title: "**Active mode per account and per rule.** Virtual mode stays the default (MAIL-007)"
date: 2026-11-27
status: proposed
---

# MAIL-116: **Active mode per account and per rule.** Virtual mode stays the default (MAIL-007)

**Decision.** **Active mode per account and per rule.** Virtual mode stays the default (MAIL-007): an account's "Organise mail at your provider" (`AccountOrganisation.isActive`) is off until you turn it on, and turning it on moves nothing by itself. A policy is turned on from its dry run (Preview & Turn On…), which then runs exactly as shown (`runCleanup` revalidates; when anything changed nothing runs and a fresh dry run says what); from then on it runs after each sync. Changing a policy's age or action turns it off until its dry run is looked at again; turning the account off turns its policies off. A sender rule's "Also archive at your mail provider" (MAIL-054) is the rule's active mode: it now needs the account's active mode too (the checkbox is offered only then; a rule already set is paused and says so), leaves flagged mail and mail in a space where it is, and its archives are steps of the History, not of Edit ▸ Undo (the rule change itself still is). The store checks active mode, the policy and the coordinating device in the same actor step that writes the journal (`MailStore.runRetention`, `runRuleArchive`)

**Why.** Features.md, Organisation modes: "opt-in per account and rule, previews scope". Checking in the store, not only in the app model, is what makes "nothing moves until active mode is on" hold for every caller. One Undo path per step (the History) avoids undoing a batch twice from two places. GKM-031

**Links.** MAIL-007, MAIL-054, GKM-031
