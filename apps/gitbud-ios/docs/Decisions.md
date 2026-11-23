# GitKittie Bud (iOS/iPadOS) — Decisions

---

### 1. iOS/iPadOS is remote-only

**Decision.** GitKittie Bud iOS and iPadOS use GitPont remote repository APIs. They do
not shell out to git or maintain full local clones for v1.

**Context.** macOS can rely on system git for full history semantics. iOS/iPadOS
cannot.

**Rationale.** Remote-only keeps mobile scope realistic and aligns with existing
GitPont use in GitKittie apps.

**Status.** Accepted.

---

### 2. Branch/PR workflows are preferred on mobile

**Decision.** Mobile edits should create branches and PRs/MRs rather than
rewriting current branch history.

**Context.** Provider APIs can safely create commits and branches, but full
history rewriting needs stronger guarantees than mobile v1 has.

**Rationale.** Mobile should be safe by default and avoid hidden destructive
operations.

**Status.** Accepted.

---

### 3. Magic uses AIPont BYOK

> Superseded by 5 for drafting: on-device first.

**Decision.** Mobile Magic uses the same AIPont BYOK model as macOS.

**Context.** Users should keep provider choice and key ownership across
platforms.

**Rationale.** One AI abstraction keeps the product behavior consistent.

**Status.** Accepted.

---

### 4. No GitKittie Bud backend or accounts

**Decision.** GitKittie Bud iOS/iPadOS uses GitPont and AIPont directly from the app.
It does not depend on GitKittie Bud accounts, a hosted GitKittie Bud backend, or GitKittie Bud-owned
sync infrastructure.

**Context.** The app may talk to the user's git provider and AI provider, but
GitKittie Bud does not operate a relay or account service.

**Rationale.** The mobile apps should preserve the same no-server trust model as
the rest of GitKittie.

**Status.** Accepted.

---

### 5. Magic drafts on the device first

**Decision.** "Draft with Apple Intelligence" uses Apple's on-device model through
`AIPontMagicService` with the `.onDevice` provider. It is hidden where the model is not available.

**Context.** Sil, 2026-11-23: use local on-device AI to suggest commits. GitKittie Bud macOS made
on-device the default the same day.

**Rationale.** No key to set up on a phone, and the chosen lines never leave the device.

**Status.** Accepted and implemented.

---

### 6. Chosen lines become a pull request through a three-way merge

**Decision.** In place of the Mac's "apply to working copy", chosen lines of a commit become a
pull request: a new branch from the target, one commit with each touched file merged three ways
(the file as the commit had it, that file with the lines picked or undone, the file on the
target), and the pull request. Everything is worked out before anything is written. The merge is
`GitLineMerge` from GitKittieKit — the same one the Mac falls back to — which keeps edits that only
touch the chosen lines and treats identical changes on both sides as no conflict.

**Context.** iOS has no working copy (Decision 1), and Decision 2 prefers branch/PR workflows.

**Status.** Accepted and implemented (GITKITTIE-079).

---

### 7. GitPont is pinned to a revision of master

**Decision.** `project.yml` takes `git-pont` from GitHub at a fixed revision of `master`
(`6c0ffa9`, the merge of git-pont#7), moved on purpose when GitPont gains something the app needs. The commit history,
commit detail and pull request list APIs the app needs were added to GitPont (git-pont#7, merged
2026-11-23) for GitHub, GitLab, Forgejo/Gitea and Bitbucket, rather than called directly from the
app.

**Status.** Accepted.
