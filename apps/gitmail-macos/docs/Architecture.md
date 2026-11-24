# Architecture

## Boundaries and providers

SwiftUI macOS first; iOS/iPadOS later. UI-independent core in a shared Swift package under swift/ (name after existing package audit). AppModel is UI-facing state. Separate provider adapter, MIME parser, store, classifier, index, sync coordinator and outbox. No cross-app imports. Reuse existing services only where appropriate.

Provider adapters expose capabilities and normalized operations: enumerate folders/labels, incremental fetch, MIME/attachments, flags, move/archive/trash, drafts, send and reconciliation. Generic IMAP/SMTP with TLS first, iCloud app-specific password; Gmail OAuth/API or approved IMAP; Outlook/Microsoft 365 OAuth/Graph or supported IMAP/SMTP. Yahoo, Fastmail and custom domains via supported protocols. Proton Bridge desktop candidate only, not mobile promise. Verify scopes, approval, quotas and enterprise policies. Credentials in Keychain, never files or Git; avoid primary passwords when supported alternatives exist.

## Storage and identity

Provider is authoritative for live mail and flags. Explicitly preserved archive files are independently owned. GitKittie metadata has separate sync; SQLite FTS5 is a rebuildable index. Suggested schema, in two places.

The mail folder holds only what the user owns and may sync, back up or put under version control:

    Mail/accounts/<account-id>/messages/<year>/<month>/<local-id>.eml
    Mail/accounts/<account-id>/messages/<year>/<month>/<local-id>.md
    Mail/blobs/<content-hash>
    Mail/archive/
    Mail/spaces/
    Mail/drafts/
    Mail/views/

Device-local state lives outside it, in the app's Application Support container, and is never synced:

    <Application Support>/Mail/index.sqlite
    <Application Support>/Mail/state/<account-id>/   (sync cursors, UIDVALIDITY, IDLE state)
    <Application Support>/Mail/cache/                (downloaded bodies and attachments not pinned)

Each device has its own position at each provider, so sync cursors are per device; in a shared folder two devices would overwrite each other's. The index is rebuilt from the folder, so losing it costs time, not data. Keeping both out of the folder means pointing GitKittie Folder, iCloud Drive or Git at `Mail/` can never commit an index on every change or mix two devices' cursors.

Preserve original RFC 5322/MIME in EML; derive readable Markdown with YAML (id, messageId, references, sender, recipients, subject, date, attachment refs). Separate mutable metadata. Markdown is not lossless HTML/MIME; retain original signatures, inline images and attachments. Atomic writes, schema migrations, safe paths and integrity hashes. Deduplicate attachment blobs within appropriate access boundaries. Attachments on demand, pin for offline. Index, cache and sync state are outside the mail folder (above), so they cannot reach Git or folder sync. Encrypted message support is separate; preserve originals without modification.

Account-scoped local UUID, provider ID where available, IMAP mailbox + UIDVALIDITY + UID as remote mapping; Message-ID/content fingerprint are reconciliation signals, not globally unique. Handle moves, UID resets, missing/duplicate IDs, aliases and Gmail label duplication. Thread graph from References/In-Reply-To with conservative fallback, never subject alone. Each message remains independent. Reply preserves recipients, Reply-To, account identity and standard headers; never expose internal tags.

## Multi-device sync

Each device connects directly to provider. Provider syncs live messages, flags, folders/labels and Sent. Incremental cursors per account/folder, checkpoint after durable writes, reconcile missed changes and UID resets. IMAP IDLE on active desktop with reconnect/backoff and polling fallback; respect throttling, network and token expiry.

Private CloudKit proposed for spaces, tags, memberships, rules, corrections, notes, preferences and pins. Explicit cross-device account mapping, not display address alone. Credentials device-local by default; authorize accounts on new devices. Explain opt-out, unavailable iCloud/quota, metadata privacy and export. Private database is not a blanket end-to-end encryption guarantee; design encrypted sensitive records and key recovery. No raw messages/attachments in metadata sync by default.

Idempotent durable operations, record revisions, change tokens and tombstones. Merge independent memberships; deterministic scalar conflicts; preserve conflicting notes/drafts. Manual classification overrides automation. Persist offline action journal and visible retry state. Reconcile provider changes before destructive operations; never resurrect deleted messages from stale cache. Avoid syncing whole SQLite database or mailbox Git repository.

Archive is third layer: preserved messages survive provider deletion. Local-only archives do not automatically appear elsewhere. Portable encrypted export first, encrypted archive sync or user-selected shared storage later, with integrity, key recovery, quota, deletion and restore tests. Distinguish provider deletion, archive deletion and cache eviction. Account disconnect offers keep/export or remove local files with consequences.

## Sending and drafts

Durable outbox, operation ID, stable outgoing Message-ID, recipient/account snapshot and queued/sending/sent/failed/uncertain states. SMTP acceptance is not delivery confirmation. If possible acceptance followed by disconnect, reconcile Sent/provider history before retry; no blind resend. Provider-specific Sent copy behavior avoids duplicates. Draft versions and conflict copies; shared draft send needs single owner where supported, never auto-submit from multiple devices. Test Bcc, reply-all, attachments, cancellations and retries.

## Background processing

macOS can monitor while running. iOS background execution is opportunistic, not guaranteed instant notifications or continuous filtering. Core mail requires no custom server. Optional self-hosted relay later for continuous monitoring and push, with explicit trust boundary, secure credentials and minimal notification payload. Do not advertise guaranteed instant push until validated.

## Security and privacy

TLS validation; no secret logging. OS data protection, optional encrypted archive, restricted file access. Sandbox HTML, disable scripts and remote loads by default; no tracking pixel fetch. Warn on suspicious URLs/impersonation; trust authentication evidence only from known boundaries. Validate attachment size/type, isolate extraction, guard against malformed MIME, decompression bombs and path traversal. Email and attachments are untrusted input, never agent instructions; local AI optional, no automatic external transfer. Explicit scoped read-only agent access by default. Redacted diagnostics. Git opt-in warns about confidentiality and persistent history; prefer metadata only. All Git host access via GitPont.

## Implementation references

Apple iCloud: https://support.apple.com/en-us/102525

Gmail API: https://developers.google.com/workspace/gmail/api

Graph mail: https://learn.microsoft.com/en-us/graph/api/resources/mail-api-overview

CloudKit: https://developer.apple.com/documentation/cloudkit/cksyncengine

IMAP RFC 9051; SMTP RFC 5321; message format RFC 5322; MIME RFC 2045–2049. Validate current provider requirements before implementation.
