# Performance: the first sync of a large mailbox

What a full first sync of 10,000 (and 50,000) messages costs, what made it slow, and what was
changed (GKM-035, 2026-11-24). Search and the list were already measured at 100,000 messages at
the index level (`SearchBenchmarkTests`); this is the sync end to end: IMAP → `SyncCoordinator`
→ `MailStore` (`.eml` + `.md` + blobs, FTS5 index, sync state) on the real local test server.

## Short answer

- **Before:** a mailbox with a folder of more than about 1,900 messages **never finished its
  first sync**: the folder's listing (`UID SEARCH ALL`) is one response line, longer than
  swift-nio-imap's default 8 KB limit, so every listing closed the connection and the sync
  retried forever. With folders kept small enough to get past that, 10,000 messages took
  156 s on this Mac, and it got slower with every message stored (134 → 30 messages/s): two
  per-message index lookups scanned the whole account, and every history slice re-read the
  flags of every stored message.
- **After:** 10,000 messages in **32 s** (311/s, steady from first to last), the first 200
  messages visible after **0.5 s**, at most 158 MB of memory. A second sync with nothing changed
  takes 0.8 s. With a 50 ms round trip in front of the server (a distant provider): **67 s**.
- **Now, with classification (GKM-017) and GKM-036/038:** 10,000 messages in about 2 minutes,
  50,000 in about 9 minutes on loopback; classification costs about 10 ms of CPU per message and
  dominates. History slices cut IMAP commands at 50,000 from 9,909 to 3,710 and disk writes from
  26 to 15 GB. See [GKM-036 and GKM-038](#gkm-036-and-gkm-038-re-measured-with-classification-2026-11-25).
- **50,000:** see [50,000 messages](#50000-messages).

## How it was measured

`SyncBenchmarkTests` (GitKittieMailProviders, MailIntegrationTests), opt-in:

    cd swift/GitKittieMailProviders
    scripts/test-mail-server.sh start
    GKM_SYNC_BENCHMARK=1 GKM_SYNC_BENCHMARK_MESSAGES=10000 \
      swift test -c release -Xswiftc -enable-testing --filter SyncBenchmarkTests

| Variable | Default | Meaning |
| --- | --- | --- |
| `GKM_SYNC_BENCHMARK_MESSAGES` | 10000 | Messages in the synthetic mailbox |
| `GKM_SYNC_BENCHMARK_FOLDER_SIZE` | 1000 | Most messages per folder (see GreenMail below) |
| `GKM_SYNC_BENCHMARK_ATTACHMENTS` | 1 | Scales the share of messages with attachments |
| `GKM_SYNC_BENCHMARK_BODY_SCALE` | 1 | Scales the text size |
| `GKM_SYNC_BENCHMARK_RTT_MS` | 0 | Round trip added by the fault proxy (`FaultProxy.slowLink`) |
| `GKM_SYNC_BENCHMARK_MBPS` | none | Link speed of the fault proxy |
| `GKM_SYNC_BENCHMARK_KEEP_FREE_GB` | 3 | Refuse to start unless this much disk stays free; stop the sync below half of it |
| `GKM_SYNC_BENCHMARK_OUT` | none | Write the results as JSON |

**The mailbox** (`SyntheticMailbox`, deterministic, reserved domains only): 65 % of messages
5–15 KB, 32 % 15–50 KB (text and HTML alternatives), 2.4 % with a 30–200 KB attachment, 0.5 %
300 KB–1 MB, 0.1 % 1–3 MB; one in ten HTML messages carries the same inline logo; about 15 % are
replies linked by In-Reply-To/References; 80 % inbox, 10 % Sent, 10 % Archive, appended oldest
first. 10,000 messages are about 309 MB at the server and 514 MB in the mail folder (originals,
Markdown, decoded attachments) plus 137 MB of device state (index 131 MB).

**The passes:** the first sync (`syncOnce`, default `SyncOptions`, as the app uses), then a pass
with nothing changed, then one after 100 new messages and 500 flag changes made by another
client (250 flagged, 250 marked unread; the test checks that every one arrived). Each reports
time, time until 200 messages are stored (and so listed), messages/s per tenth of the import,
peak memory footprint, CPU (client and server), bytes written to disk (kernel counters), the
store's file writes, fsyncs and SQLite commits (`StoreIOStatistics`), and IMAP commands.

**The machine:** a MacBook with Apple silicon, shared with other builds while measuring, so
treat a few seconds either way as noise.

### Two things about the test server

- **GreenMail answers `UID FETCH` in time proportional to the folder's size for each message
  it returns** (`ImapSessionFolder.getMsn` rebuilds the folder's UID list per message), so a
  10,000-message inbox measures GreenMail, not the sync: an early run with one inbox of 8,000
  spent its time in the server at 100 % CPU while the client idled. The benchmark therefore
  splits folders at 1,000 messages ("INBOX", "Inbox 2", …). Real servers (Dovecot, iCloud) look
  UIDs up directly. A single folder of 2,000 is covered by `LargeFolderSyncTests`.
- **GreenMail has no CONDSTORE**, so every flag check here is the full fallback (read the
  flags of every stored message). Against a server with CONDSTORE (#34, MAIL-037) the
  "nothing changed" and flag passes read only what changed since the last HIGHESTMODSEQ, so
  they will be faster there than the numbers below.

## 10,000 messages: before and after

Loopback, no added latency. "Before" is `main` at 481ff1c (with folders of at most 1,000, the
largest it could sync); "after" is this branch merged with `main` after #34.

| | Before | After |
| --- | ---: | ---: |
| First sync, total | 155.7 s | **32.1 s** |
| Messages/s, overall | 64 | **311** |
| Messages/s by tenth | 134 153 133 120 81 72 46 35 30 62 | 348 297 323 351 322 329 301 274 298 351 |
| First 200 visible | 1.32 s | **0.47 s** |
| Peak memory footprint | 75 MB | 158 MB |
| CPU, client (server) | 91.2 s (21.5 s) | 23.6 s (7.2 s) |
| Bytes written to disk | 3,758 MB | 1,721 MB |
| Files written / file fsyncs | 30,329 / 30,329 | 20,438 / 20,438 |
| Directory fsyncs | 30,329 | 428 |
| Index commits | 30,176 | 394 |
| Sync-state commits (each flushes the WAL) | 30,380 | 707 |
| IMAP commands | 1,283 | 607 |
| Mail folder / device state | 514 MB / 138 MB | 514 MB / 137 MB |
| Second pass, nothing changed | 0.8 s, 59 commands | 0.8 s, 59 commands |
| 100 new + 500 flag changes | 2.8 s | 1.2 s |

Each step, measured on its own (same mailbox, loopback):

| Step | First sync | Messages/s by tenth |
| --- | ---: | --- |
| Before | 155.7 s | 134 → 30 (slower with every message) |
| + index lookups use their indexes | 72.6 s | 146 … 140 (flat) |
| + flags checked once per history import, not per slice | 57.6 s | 193 … 176 |
| + a fetched batch stored with shared flushes and commits | 39.4 s | 293 … 225 |
| + body fetches of up to 100 messages (was 25), merged with #34 | 32.1 s | 348 … 351 |

Memory grew from 75 to 158 MB with the larger body batches (up to 100 messages or 8 MB per
fetch, held while they are stored); it does not grow with the mailbox.

## What was slow, and what changed

1. **Large folders could not be listed** (`fix(mail)`, MAIL-048). `UID SEARCH ALL` answers on
   one line; above about 1,900 messages it passed swift-nio-imap's 8 KB line limit and the
   connection closed. `IMAPConnector` now accepts lines up to 16 MiB (about two million UIDs);
   bodies are still streamed and limited separately. Tests: `LargeResponseTests` (60,000 UIDs
   arriving in 4 KB pieces; and the library default refusing 2,000), `LargeFolderSyncTests`
   (a 2,000-message folder against the server).
2. **Two lookups per arriving message scanned the account.** Reconciliation candidates were one
   query with `OR` over optional parameters, so SQLite used neither index; the "is this
   Message-ID ambiguous" check in threading used `count(DISTINCT fingerprint)`, for which SQLite
   chose to walk the fingerprint index over the whole account. Both now use their indexes
   (`MailIndex.candidatesSQL`, `claimantsSQL`), pinned by `IndexQueryPlanTests`. This alone made
   the import rate flat instead of falling.
3. **Every history slice re-read every flag** (MAIL-047). The sync imports history 500 messages
   per pass, and each pass checked the flags of every stored message: quadratic in the mailbox
   size, in both server work and round trips. Passes that only continue a history import now
   check flags at most every two minutes (`SyncOptions.flagCheckInterval`) and once when the
   history is complete; new mail is still checked first on every pass. `LargeFolderSyncTests`
   counts the flag reads.
4. **About 12 flushes and commits per message** (MAIL-046). Each message wrote a journal file,
   its `.md` and `.eml` (each fsynced, each directory fsynced), then three index and three
   sync-state commits. `MailStore.storeSynced` stores a fetched batch at once: one journal file
   for the batch, each file still flushed before its rename, each directory flushed once, one
   index transaction and one sync-state transaction, flags and the downloaded byte count once.
   The per-message guarantee is unchanged: a message is wholly there (its `.eml` was renamed
   into place; recovery completes the rest from the journal) or wholly absent. `ingest` uses
   the same path for one message. `SyncBatchTests` kills a batch at every step, halfway through
   included; the existing crash tests run unchanged.
5. **Round trips.** A body fetch now takes up to 100 messages (still at most 8 MB), a quarter
   of the commands; on a 50 ms link this took the first sync from 115 s to 61 s.

## A real provider: latency

The fault proxy can delay every byte by half a round trip each way (`FaultProxy(mode:
.slowLink(...))`), with an optional link speed. With a 50 ms round trip:

| 10,000 messages, 50 ms round trip | Before step 5 (25 per fetch) | After |
| --- | ---: | ---: |
| First sync | 114.8 s | **66.5 s** (150/s) |
| First 200 visible | 3.18 s | 2.18 s |
| Nothing changed | 4.3 s | 4.1 s |
| 100 new + 500 flag changes | 5.3 s | 4.8 s |

(The code before all fixes was not run through the proxy; its 1,283 commands alone add about
64 s at 50 ms, on top of its 156 s.)

The proxy adds latency, not a bandwidth limit, so for a real iCloud account add the transfer
time: 309 MB is about 50 s at 50 Mbit/s and about 25 s at 100 Mbit/s, partly overlapping the
round trips. **Estimate for 10,000 typical messages from iCloud: about 1½ to 2 minutes**, the
newest 200 in the list within a few seconds. Apple publishes no IMAP download limit for iCloud
Mail; the limits in ProviderAccess.md (1,000 messages and 1,000 recipients a day, 20 MB per
message) are for sending. Not measured against iCloud itself (GKM-004).

## 50,000 messages

Measured on 2026-11-25: see [GKM-036 and GKM-038](#gkm-036-and-gkm-038-re-measured-with-classification-2026-11-25).
Before that, the 50,000-message run was stopped twice because the shared disk filled up
(other builds on the same volume); the benchmark now stops the sync itself when free space falls
below half of `GKM_SYNC_BENCHMARK_KEEP_FREE_GB`. What the 10,000 run shows about 50,000:

- **After, storing:** the import rate is flat from the first to the last tenth and memory does
  not grow with the mailbox, so storing 50,000 messages of the same mix is about five times the
  10,000 time: roughly 3 minutes on loopback.
- **After, re-listing:** one cost still grows faster than the mailbox. Between history slices
  (500 messages) every pass lists every folder again (`SELECT` + `UID SEARCH ALL`), so new mail
  is never hidden behind history. Of the 607 commands at 10,000, about 390 are these listings
  (17 passes × 11 folders × 2, plus the folder list). At 50,000 in a few large folders that is
  about 100 passes, each transferring and parsing every UID (a 40,000-message inbox answers
  with about 250 KB per listing; swift-nio-imap parsed 60,000 UIDs in about 2 s in
  `LargeResponseTests`, arriving in 4 KB pieces), so on the order of minutes of listing on top.
  Larger or time-based history slices would cut this; not done here because it could not be
  measured (below).
- **Before:** each message cost about 7.5 ms plus about 3 µs per message already stored
  (fitted from the falling rate), so 50,000 would have taken over an hour, and a single folder of
  that size never finished at all.

**Classification (GKM-017, #33) came after these numbers.** Since the merge it runs on every
message a batch writes, after the batch is durable, in one index transaction for the batch. The
numbers above were measured without it; re-measure with GKM-038.

## GKM-036 and GKM-038: re-measured with classification (2026-11-25)

Three changes since the numbers above: history slices end after 20 s or 10,000 messages instead
of 500 messages (MAIL-065); fetching overlaps storing (MAIL-066); and attachments over 1 MB stay at
the provider until opened or pinned (MAIL-062). Classification (GKM-017) has run on every stored
message since #33. Each run below is "current" against "legacy" on **the same build**
(`GKM_SYNC_BENCHMARK_LEGACY=1`: 500-message slices, whole messages, no overlap), so the
difference is these changes alone; both include classification. Same Mac, shared with other work.

| 10,000 messages (default mix) | Legacy | Current |
| --- | ---: | ---: |
| First sync, loopback | 115.1 s (87/s) | 127.2 s (79/s) |
| First 200 visible | 2.06 s | 2.19 s |
| CPU, client (server) | 105.0 s (6.3 s) | 114.9 s (8.2 s) |
| IMAP commands | 607 | **378** |
| Bytes written to disk | 1,928 MB | 1,737 MB |
| Mail folder / device state | 514 / 159 MB | **423** / 159 MB |
| Stored partially (attachments at the provider) | 0 | 30 |
| First sync, 50 ms round trip | 153.8 s (65/s) | **135.8 s (74/s)** |
| First 200 visible, 50 ms | 3.81 s | 3.71 s |
| Nothing changed / 100 new + 500 flags, 50 ms | 4.1 s / 5.6 s | 4.0 s / 5.6 s |

| 50,000 messages (`BODY_SCALE=0.4`, `ATTACHMENTS=0.25`, 52 folders, 578 MB) | Legacy | Current |
| --- | ---: | ---: |
| First sync, loopback | 563.7 s (89/s) | **524.3 s (95/s)** |
| Messages/s by tenth | 116 134 126 117 96 90 74 72 67 64 | 176 166 148 129 97 93 86 72 73 57 |
| First 200 visible | 1.19 s | 1.32 s |
| CPU, client (server) | 481.7 s (41.5 s) | 467.5 s (38.3 s) |
| IMAP commands | 9,909 | **3,710** |
| Bytes written to disk | 26,015 MB | **15,319 MB** |
| Index / sync-state commits | 5,663 / 9,955 | 2,700 / 3,865 |
| Peak memory footprint | 94 MB | 82 MB |
| Mail folder / device state | 1,036 / 422 MB | 932 / 425 MB |
| Nothing changed / 100 new + 500 flags | 4.8 s / 6.0 s | 4.4 s / 6.0 s |

What this says:

- **The slices did what they were for.** At 50,000, IMAP commands fell from 9,909 to 3,710 and
  disk writes from 26 GB to 15 GB (fewer passes, so fewer listings, fewer flag and cursor
  commits). On a 50 ms link the 10,000 first sync is 12 % faster.
- **Classification now dominates.** The first sync is CPU-bound in the client: about 10 ms of
  CPU per message (115 s for 10,000, against 23.6 s before classification), so overlap gains
  little on loopback (the store is the bottleneck either way; the loopback 10,000 runs differ by
  about the noise of a shared machine). The 32 s in the tables above no longer holds: **a first
  sync of 10,000 messages takes about 2 minutes, 50,000 about 9 minutes**, before network time.
- **It still slows as the mailbox grows**: at 50,000 the rate falls from 176 to 57 messages/s in
  both modes, while storing alone was flat (above). Something per message grows with the
  number already stored; the CPU is in the client, not the server. Not found yet: GKM-040.
- **Partial messages** (1–3 MB attachments, 0.1 % of the mix) kept 91 MB of attachments out of
  the mail folder at 10,000; the first sync's numbers are otherwise unaffected, as intended.

Run it yourself (each again with `GKM_SYNC_BENCHMARK_LEGACY=1`, and with `GKM_SYNC_BENCHMARK_RTT_MS=50`):

    GKM_SYNC_BENCHMARK=1 GKM_SYNC_BENCHMARK_MESSAGES=10000 \
      swift test -c release -Xswiftc -enable-testing --filter SyncBenchmarkTests
    GKM_SYNC_BENCHMARK=1 GKM_SYNC_BENCHMARK_MESSAGES=50000 GKM_SYNC_BENCHMARK_BODY_SCALE=0.4 \
      GKM_SYNC_BENCHMARK_ATTACHMENTS=0.25 swift test -c release -Xswiftc -enable-testing --filter SyncBenchmarkTests

## What is left

- **Classification cost and the falling rate (GKM-040).** About 10 ms of client CPU per message,
  and at 50,000 the rate falls from 176 to 57 messages/s: something per message grows with the
  mailbox. Profile the store with classification on (sender/correspondent statistics and the
  per-batch classification transaction are the first suspects) and make it flat again.
- **Overlap on loopback.** Fetch and store overlap (MAIL-066), but while classification makes the
  store the bottleneck it gains only on a slow link (12 % at 50 ms).
- **CONDSTORE in the benchmark.** GreenMail has none; run the benchmark against a server with it
  (or iCloud, GKM-004) to measure the flag passes as they will be.
- **Write amplification.** 15 GB is written for about 1.4 GB stored at 50,000: every file is
  written and flushed once, and SQLite's WAL writes index pages and checkpoints them again.
  Bigger index transactions or a larger `wal_autocheckpoint` would lower it.
