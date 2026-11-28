---
id: MAIL-054
title: "Sender and list rules (inbox, silent archive, category, mute, keep transactions only,..."
date: 2026-11-24
status: proposed
---

# MAIL-054: Sender and list rules (inbox, silent archive, category, mute, keep transactions only,...

**Decision.** Sender and list rules (inbox, silent archive, category, mute, keep transactions only, keep latest only) are user data in `metadata/sender-rules.json`, a file of their own beside `classification.json` so GKM-026 can sync them as their own record type. They are applied where verdicts are made (`MailStore.plan`), on arrival, rebuild, rule-set upgrade and rule change alike, and stored with the verdict: index schema 5 adds the winning `sender_rule` and its `disposition` (`inbox`, `archived`, `muted`) to `message_classes`, migrated with two `ALTER TABLE`s, not rebuilt. Muted mail leaves Focused and the category views; silently archived mail leaves Focused only; both are silent (no badge, no notification) and stay in All Mail, accounts and folders. Rules are virtual: they never change provider folders or flags, unless a rule is set to "also archive at your provider", which sends Archive through the action journal (MAIL-034) for what it silenced, at apply time and for new mail after each sync. Rules never act on risky mail (spam, phishing, suspicious), never hide account-security mail, and a correction of one message wins over any rule; a category rule goes through the classifier and so never lowers risk

**Why.** Lose the noise without losing receipts or warnings (Classification.md, Sender and subscription management); one evaluation path is what makes "the preview matches what it does" true by construction. GKM-019

**Links.** GKM-026, MAIL-034, GKM-019
