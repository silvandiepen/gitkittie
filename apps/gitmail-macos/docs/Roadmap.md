# Implementation roadmap

All phases proposed, not shipped.

## 0. Feasibility

Audit shared code, select provider/MIME libraries and synthetic fixtures. Real iCloud test account: TLS app password, folders/messages/flags/attachments, send and Sent reconciliation, moves, UID reset, reconnect, malformed messages. Prototype EML/Markdown, stable IDs, FTS5 rebuild and storage budgets. Threat model and classifier baseline. Gate: real end-to-end send/receive, durable storage, no secrets in logs.

## 1. macOS mail foundation

Native UI, account onboarding, progressive import, threads, compose/reply/forward, drafts, durable outbox, attachments, normal flags/moves/trash, offline read and safe HTML. Test multiple accounts, large mailbox, network loss and duplicate headers. Gate: reliable everyday use alongside Apple Mail; uncertain SMTP state visible, no blind retries.

## 2. Differentiating MVP

Gmail account support (MAIL-014), read-only classifier, focused inbox and category views, sender/list management, explanations, corrections, notification filtering, cleanup preview, local search. Safe confirmed unsubscribe/manual batch actions, Spaces, attachment library, EML+Markdown export. Test with people overwhelmed by marketing. Gate: agreed important-mail recall threshold, ambiguous items visible, all suggestions inspectable, no automatic destructive actions.

## 3. Multi-device and iOS/iPadOS

Shared core, native mobile UI, private CloudKit metadata, account authorization, conflicts, outbox coordination, incremental fetch, storage controls, backup/restore and accessibility. Test two real devices, simultaneous rules/tags/drafts/deletion, offline edits, new device and unavailable iCloud. Gate: convergence without loss or duplicate sends; honest background limitations.

## 4. More providers and controlled automation

Outlook and Microsoft 365 adapter after authentication verification, label semantics, migration and capability tests. Opt-in active organisation, dry run, audit, protected retention and reversible cleanup. Encrypted archive sync feasibility, optional Git metadata export via GitPont, Tasks integration and scoped agent access.

## Later

Local semantic search, optional self-hosted continuous processing/push relay, richer project views and further providers only when demand justifies maintenance.

## Launch gates

Real provider compatibility, recovery/export, security/privacy review, VoiceOver and keyboard navigation, transparent push limitations, OAuth approval where needed, App Store review, support/terms/privacy pages, marketing claims matching shipped features and validated pricing. No mandatory server or AI subscription for core mail.
