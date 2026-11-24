# Spam, marketing and attention management

## Taxonomy

Purpose, security risk, urgency, workflow and space membership are separate dimensions. Category is per message, not domain.

| Purpose | Examples | Default attention |
| --- | --- | --- |
| Conversation | Personal, support | Inbox |
| Transaction | Receipts, orders, invoices, travel | Actionable items in Inbox; all in Transactions |
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
