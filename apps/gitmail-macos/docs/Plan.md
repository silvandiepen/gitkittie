# Plan

The work breakdown for GitKittie Mail. Roadmap.md says what each phase is for; this says what gets built, in which order, and what must be true before the next phase starts. Every step is a card on the GitKittie board (product `mail`, epic `gitkittie-mail`, ids `GKM-…`). The cards are the live status; this page is the map.

All of it is proposed. Nothing here is shipped.

## Before anything is built

Sil decided the open questions on 2026-11-24 (GKM-001, recorded in Decisions.md): Git optional with iCloud for metadata, iCloud plus any IMAP account plus Gmail at first release, pricing after the MVP tests, code in this monorepo. GKM-008 costs Gmail access before Phase 2 depends on it.

## Order of work

Within a phase, cards without an unfinished dependency can run in parallel. A phase starts when the previous phase's gate is met.

### Phase 0 — Feasibility

Prove the risky parts before any app exists: a real provider, durable storage, the threat model and a classifier baseline.

| Card | Task | Priority | Needs |
| --- | --- | --- | --- |
| GKM-001 | Decide how Mail fits GitKittie: Git optional, iCloud for metadata | P1 | — |
| GKM-002 | Choose the IMAP, SMTP and MIME libraries | P1 | — |
| GKM-003 | Build a synthetic mail fixture corpus | P1 | — |
| GKM-004 | Spike iCloud mail end to end | P1 | GKM-002 |
| GKM-005 | Prototype storage: EML, derived Markdown, stable IDs and a rebuildable index | P1 | GKM-003 |
| GKM-006 | Write the Mail threat model | P1 | — |
| GKM-007 | Classifier baseline on the fixture corpus | P2 | GKM-003 |
| GKM-008 | Cost Gmail and Microsoft access before committing to them | P1 | — |

**Gate:** Real end-to-end send and receive against iCloud, durable storage that survives a crash, no secrets in logs, and Sil's answers to the open questions.

### Phase 1 — macOS mail foundation

An everyday mail client for one provider, reliable enough to use next to Apple Mail.

| Card | Task | Priority | Needs |
| --- | --- | --- | --- |
| GKM-009 | Scaffold the macOS app and the shared Mail package | P1 | GKM-001, GKM-002, GKM-005 |
| GKM-010 | Add an iCloud or IMAP account, credentials in the Keychain | P1 | GKM-004, GKM-009 |
| GKM-011 | Import and keep mail in sync: progressive, incremental, IDLE | P1 | GKM-005, GKM-010 |
| GKM-012 | Message list, threads and a safe reader | P1 | GKM-011, GKM-006 |
| GKM-013 | Compose, reply, forward and drafts | P1 | GKM-012 |
| GKM-014 | A durable outbox that never sends twice | P0 | GKM-013 |
| GKM-015 | Everyday actions: flags, archive, move, trash, attachments, offline | P1 | GKM-012 |
| GKM-016 | Local search with filters | P2 | GKM-005, GKM-011 |

**Gate:** Reliable everyday use alongside Apple Mail; an uncertain SMTP send is visible and never retried blindly.

### Phase 2 — Differentiating MVP

What makes people switch: a calmer inbox, sender control, safe cleanup and Spaces.

| Card | Task | Priority | Needs |
| --- | --- | --- | --- |
| GKM-017 | Classify mail read-only, with reasons and corrections | P1 | GKM-007, GKM-011 |
| GKM-018 | Focused inbox, category views and quiet notifications | P1 | GKM-017 |
| GKM-019 | Sender and list management | P2 | GKM-017 |
| GKM-020 | Unsubscribe safely | P1 | GKM-019, GKM-006 |
| GKM-021 | Cleanup dashboard with exact previews | P2 | GKM-017, GKM-015 |
| GKM-022 | Spaces: projects across accounts | P2 | GKM-017 |
| GKM-023 | Attachment library and EML plus Markdown export | P2 | GKM-005 |
| GKM-029 | Gmail adapter | P1 | GKM-008, GKM-011 |
| GKM-024 | Test the MVP with people overwhelmed by marketing mail | P1 | GKM-018, GKM-019, GKM-020, GKM-021, GKM-022, GKM-029 |

**Gate:** Important-mail recall at the agreed threshold, ambiguous items visible, every suggestion inspectable, no automatic destructive action.

### Phase 3 — Multi-device and iOS/iPadOS

The same mail and organisation on every Apple device.

| Card | Task | Priority | Needs |
| --- | --- | --- | --- |
| GKM-025 | Share the Mail core between macOS and iOS | P2 | GKM-024 |
| GKM-026 | Sync spaces, rules and corrections through private CloudKit | P2 | GKM-001, GKM-022, GKM-025 |
| GKM-027 | Mail for iPhone and iPad | P2 | GKM-025, GKM-026 |
| GKM-028 | Coordinate the outbox and drafts across devices | P1 | GKM-014, GKM-026 |

**Gate:** Two real devices converge without loss or duplicate sends; background limits are stated honestly.

### Phase 4 — More providers and controlled automation

Microsoft, opt-in active organisation, archive sync and integrations.

| Card | Task | Priority | Needs |
| --- | --- | --- | --- |
| GKM-030 | Outlook and Microsoft 365 adapter | P3 | GKM-008, GKM-011 |
| GKM-031 | Opt-in active organisation and retention | P2 | GKM-021, GKM-017 |
| GKM-032 | Encrypted archive export and archive sync feasibility | P3 | GKM-023, GKM-006 |
| GKM-033 | Tasks link, Git metadata export via GitPont, and scoped agent access | P3 | GKM-001, GKM-017 |
| GKM-107 | Export message metadata to Git through GitPont (split from GKM-033) | P3 | GKM-033 |
| GKM-108 | Read-only agent access per space or account (split from GKM-033) | P3 | GKM-033 |

**Gate:** Each provider passes the capability tests; every automatic action is opt-in, previewed, audited and reversible.

### Launch

Everything the App Store and the site need before Mail is offered to anyone.

| Card | Task | Priority | Needs |
| --- | --- | --- | --- |
| GKM-034 | Launch readiness: accessibility, legal pages, pricing and App Store | P1 | GKM-024, GKM-006, GKM-029 |

**Gate:** The launch gates in Roadmap.md are met and every public claim matches a shipped feature.

## Critical path

GKM-002 → GKM-004 → GKM-010 → GKM-011 → GKM-012 → GKM-013 → GKM-014 (the outbox) is the longest chain to a usable client. GKM-014 is the only P0: sending a message twice, or silently not at all, is the one failure a mail client cannot have.

## Keeping this page true

When a card is added, split or dropped, update this table in the same change. When a decision changes the plan, record it in Decisions.md first.
