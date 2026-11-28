---
id: TASKS-20
section: "§ 20"
title: "Review as a first-class feature: format, model and tools (GITKITTIE-131 … 134)"
date: 2026-11-28
status: accepted
---

# § 20. Review as a first-class feature: format, model and tools (GITKITTIE-131 … 134)

**Context.** The spec (`docs/ReviewSpec.md`, PR #93) and Sil's answers: actions run automatically
on the last decision with Undo (`when: auto-undo`), conflicts are skipped with "Move anyway?"
(`conflict: skip-ask`), others' requests are behind a For me / Everyone filter and read-only
(`visibility: filter-readonly`), first release = gaps 1–6 (`scope: core`). Six questions were not
answered; the spec's recommendations are used until Sil says otherwise: changes > reject > accept
(`outcome`), accept/changes fill the card's `reviewer` / `review_outcome` / `review_completed_at`
(`review-fields`), any one person in `for` decides (`several`), ask once per board who you are
(`identity`), scaled preview on iPhone (`phone-sizes`, UI PR), no AppleScript browser sizing
(`browser-sizing`).

**Decisions made while building it (not in the spec):**

- **`outcome` is computed, never stored** (`reviewOutcome` / `ReviewRequest.outcome`): a stored copy
  would go stale on the next decision. `list_reviews` reports it.
- **`actions_run` entries carry `before`**: the card fields the action changed, as they were, so
  Undo can restore them (the spec says Undo restores them but gives the entry no place for them).
  Undo only sets `undone_at`; `result` stays `moved` (append-only, as the spec says of the list).
- **Undo is valid while the card's `updated_at` is the action's `at`**: the action writes the card
  with that exact stamp.
- **Writes keep a request's text** (`ReviewYAMLSplice`): every key, list entry and line a write does
  not change keeps its exact bytes; only the changed part is serialized, at the indentation the
  file used. Checked by reading the result back; anything the splice cannot place falls back to the
  old whole-file serialization. On the 81 real requests (with `GITKITTIE_REVIEW_FIXTURES`), a no-op
  write is byte-identical and a decision changes only that item's lines.
- **Checks are answered per size key** (`phone` / `phone.dark`), each answer with its own `at`, and
  merged answer by answer in the outbox, like decisions.
- **The read-only rule lives in `rewriteReview`**: any decision-like edit (decision, answer, check
  decision, answer or screenshot) on a request that is not for you is refused with "For Herma. You
  can comment."; comments go through.
- **Counts follow `for`**: `BoardReviews.me` is who you are on that board; `pending`, `open`, the
  badge and local notifications count only requests for you or for everyone, so a request newly put
  on you is announced as new.
- **The relay keeps a login key, not the login**: SHA-256 of `<repo id>:<github login>` from
  `GET /user` at registration; the alert's audience is a list of such keys. It still links a device
  to an account: the App Store privacy label needs a look before release (docs/Push.md).
- **Actions run through the app's own source** (`reviewSource`), so an offline move is queued in the
  outbox after the review edit. Re-validating it when it is sent and committing review and card in
  one commit (`.batchCommit`) are left for a follow-up.
- **`list_reviews` `for`** returns requests the user decides *and* those for anyone, as the For me
  filter does.

**Status.** Accepted (model, tools and CLI; the screens are GITKITTIE-135/136).
