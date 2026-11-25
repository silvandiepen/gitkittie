# Spam, marketing and attention management

## Taxonomy

Purpose, security risk, urgency, workflow and space membership are separate dimensions. Category is per message, not domain.

| Purpose | Examples | Default attention |
| --- | --- | --- |
| Conversation | Personal, support | Inbox |
| Transaction | Receipts, orders, invoices, travel | Actionable items in Focused; receipts in Focused until read (MAIL-076); all in Transactions |
| Security | Account alerts, verification | Inbox when trustworthy; suspicious flagged |
| Notification | GitHub, deliveries, routine updates | Updates; priority exceptions |
| Subscription | Editorial newsletters, digests | Subscriptions |
| Promotion | Offers, campaigns | Promotions; silent |
| Unknown | Insufficient evidence | Visible review / Inbox |
| Spam/phishing risk | Junk verdict, impersonation | Quarantine with review |

A receipt containing an offer remains transactional; a human reply to a campaign may be conversation. A phishing invoice is not trusted transactional mail. Never suppress important mail merely because sender is no-reply or bulk.

## Classifier

1. Ingest provider spam verdicts and existing labels/folders.
2. Extract safe signals: List-ID, List-Unsubscribe, List-Unsubscribe-Post, precedence, sender/reply-to, references, trusted authentication evidence and MIME/body features. Headers can be forged.
3. Apply explicit user overrides and scoped rules; trust display names alone never bypasses security warnings.
4. Deterministic patterns for list, receipt, security, notification and promotional templates.
5. Lightweight local model for ambiguity; optional local LLM later, no mandatory external AI.
6. Output purpose, risk, urgency, confidence, reason codes, evidence and rule/model version. Keep low-confidence items visible; corrections take priority and may offer a scoped rule, never silently generalize.

Evaluate multilingual synthetic and consenting-user fixtures. False suppression of important mail costs more than missed promotions. Test mixed content, impersonation, support replies, unfamiliar senders and drift. Model upgrades must preserve manual corrections and never trigger destructive actions silently.

## Sender and subscription management

Company grouping is informational, not proof of shared ownership. Rule identity prefers account + verified sender + List-ID/provider list identity. Distinguish transactional streams from campaigns. Show count, categories, last seen, local open history (incomplete across other clients), retention. No tracking pixels. Actions: inbox, silent archive, category, mute list, keep transactions, keep latest digest, unsubscribe, quarantine, scoped block and batch review. Explicit rule ordering, reason for winning rule, preview scope/exclusions, disable, undo, dry run.

## Unsubscribe

Support legitimate List-Unsubscribe and RFC 8058 one-click where applicable after explicit user approval and validation of trustworthy list context. Never fetch links during scanning, blindly follow redirects, submit credentials, open suspicious links or confirm address to suspected spammers. Use provider report-spam for malicious mail. Preview mailto request; unsupported mechanisms manual with warning. Track requested/pending/failed/confirmed; request sent does not prove success. Local mute available independently.

## Retention

Suggested durations, never automatic destructive defaults:

| Type | Suggested retention |
| --- | --- |
| Conversations, contracts, receipts, orders, invoices | Indefinite |
| Newsletters | 90 days |
| Promotions | 30 days |
| Routine updates | 30 days |
| Expired verification codes | 7 days |
| Confirmed spam | 14 days, provider policy permitting |

Opt-in per account/category/rule. Distinguish cache eviction, provider archive, Trash and purge. No automatic permanent purge in MVP. Protect starred, pinned, linked, preserved, uncertain, legally/business-important mail and relevant thread content. Preview exact affected scope; offer exceptions, recovery and explain provider Trash limits. Revalidate latest rules and provider state before executing. Audit action reason, time, account, operation ID and undo status without full mail content. Single coordinating device/service for automatic retention; pause destructive operations offline until reconciled. Batch actions idempotent.

Cleanup dashboard: category breakdown, noisy senders, expired offers, redundant digests, storage candidates and sample matches. Initial analysis read-only at provider. Never claim all suggested mail safe to remove. Explicit confirmation for batch changes.

## Notifications

Separate unread from attention. Focused inbox and important trustworthy alerts count by default. Promotions, newsletters and routine updates silent. Customise account/list/space; All Mail, review and category counters always available. Respect OS permissions and background limits.

## Acceptance criteria

- Retailer receipt and offer classified differently; spoofed trusted sender flagged.
- Unknown important messages visible; manual corrections converge across devices.
- Virtual classification never moves/deletes provider mail.
- Cleanup preview matches execution and protected items survive.
- Unsubscribe approved and suspicious endpoints never contacted automatically.
- Remote images blocked by default; no duplicated rule/retention actions across devices.

## What exists (GKM-017, GKM-018)

**Classifier** (`MailClassifier`, rule set `gkm-rules-2`). Steps 1–4 above, deterministic, no model and no network. Organisation domains come from the bundled Public Suffix List. Changes from the GKM-007 baseline, each with fixtures and tests:

- The provider's junk folder (`Junk`, `[Gmail]/Spam`, …) counts as its spam verdict; over IMAP that is how a verdict arrives.
- A link that shows the sender's own site but goes through a mailing service's click tracker is tracking (`content.tracked-link`), not deception, when the message is bulk mail and claims nothing about an account or a payment. Otherwise a mismatch is still phishing.
- A person posting to a discussion list (`List-Post`, not `NO`; no role address, no one-click unsubscribe, no offer) is a conversation (`list.discussion`).
- Security templates only count when a function sent the message (role address, list or automation headers); a person mentioning a password, or replying about anything, is having a conversation. The claim still counts for risk.
- "Your order" with an offer in the subject and no order number in the body is a promotion (`template.offer-not-order`).
- Transactions carry urgency (MAIL-040), so only the ones to act on reach Focused. Urgency is decided after corrections, so "Not phishing" restores it.
- A bare public suffix is no organisation: never trusted, never a lookalike.

Accuracy: 63/63 on the corpus (56 GKM-003 fixtures plus 7 for the weaknesses), both through the classifier and end to end through the store. The corpus agrees with the rules by construction; real-world accuracy needs the GKM-024 held-out set. Spam without a provider verdict is still weak (two scam phrases or a junk folder).

**Storage** (MAIL-038, MAIL-039). The store classifies each message when it is stored, read-only, and keeps the verdict in the index. Corrections and rules live in device metadata, apart from the index. Tests prove the mail folder, the provider flags and folders are unchanged by classifying, correcting and ruling.

**Views and attention** (MAIL-040, MAIL-041). Sidebar: Focused, Transactions, Updates, Subscriptions, Promotions, Quarantine, All Mail; a `Category` search chip and `category:` in the search field. The reader says where a message is and why ("Why?"), and offers Move to …, Not Phishing / Not Junk, Report as Phishing, Undo, per-list notifications, and, after a purpose correction only, a rule for this sender or list.

**Cleanup dashboard** (GKM-021, MAIL-058..061). Clean Up in the sidebar reads the index only: mail per account and category, noisy senders and lists, ended offers, recurring digests (newest kept) and large attachments, each with samples. Archive, Move to Trash and Move are previewed exactly (what changes, what is left alone and why, what is not affected) with checkboxes to keep any message; protected mail is never included; Run asks for confirmation, revalidates against the latest provider state, verdicts, rules and spaces in the same store step that writes the journal, and is one Undo. Mute and "Always list under …" for a sender or list hand over to the Senders view's rules and their preview. Tests: `Tests/CleanupTests.swift`. Not yet: retention (GKM-031), an audit log of runs, dates written as numbers in offers.

**Not yet:** a local model (step 5); spaces in notification settings (GKM-022); opening a message from its notification; verified `authserv-id`s (GKM-004 for iCloud, GKM-029 for Gmail), so in the app authentication is "no evidence" and the trusted-sender list stays empty, which leaves lookalike checks to the sender warnings in the reader.

## What exists (GKM-019, GKM-020)

**Senders view** (sidebar, under All Mail). Every sender and mailing list per account: messages, the last 30 days, unread, first and last seen, where its mail lands, how much your rules silenced, opens in this app on this Mac (incomplete by design), suggested retention (nothing is deleted). Lists are grouped with the organisation that sends them, so a copied List-ID shows separately; the organisation line is for reference only.

**Rules** (MAIL-054, MAIL-055): Always in Focused, Archive Silently, Always in a category, Mute, Keep Receipts Only, Keep Latest Only; one ordered list, first match wins. Every change opens a dry run listing what moves, what stays and why (risky, corrected by you, account security, kept receipt, newest digest), with checkboxes to keep messages out; Apply saves exactly that, Edit ▸ Undo takes it back. The reader's "Why?" names the rule that won and the others that also matched. Rules are virtual unless one is set to also archive at the provider (through the action journal).

**Unsubscribe** (MAIL-056, MAIL-057): in the sender's page. One-click after a sheet that names the host and says what is sent; mailto as a previewed message through the outbox; anything else opens the list's page only after a warning. Spam, phishing and doubtful senders get Report as Junk and Mute instead. Each request shows Requested, Pending, Unsubscribed or Didn't Work, with "It Stopped" and "Still Getting Mail". Proven by `UnsubscribeTests` and `SendersAppTests` against a local HTTP server that records every request.

**Not yet:** rules by sender domain or company (deliberately not offered: a domain is no proof of one company); retention per sender (GKM-031); the cleanup dashboard's batch view of these rules (GKM-021); DKIM-verified list identity (needs verified Authentication-Results, GKM-004/GKM-029).
