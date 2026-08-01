# GitBud (iOS/iPadOS) — Decisions

---

### 1. iOS/iPadOS is remote-only

**Decision.** GitBud iOS and iPadOS use GitPont remote repository APIs. They do
not shell out to git or maintain full local clones for v1.

**Context.** macOS can rely on system git for full history semantics. iOS/iPadOS
cannot.

**Rationale.** Remote-only keeps mobile scope realistic and aligns with existing
GitPont use in GitKit apps.

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

**Decision.** Mobile Magic uses the same AIPont BYOK model as macOS.

**Context.** Users should keep provider choice and key ownership across
platforms.

**Rationale.** One AI abstraction keeps the product behavior consistent.

**Status.** Accepted.

---

### 4. No GitBud backend or accounts

**Decision.** GitBud iOS/iPadOS uses GitPont and AIPont directly from the app.
It does not depend on GitBud accounts, a hosted GitBud backend, or GitBud-owned
sync infrastructure.

**Context.** The app may talk to the user's git provider and AI provider, but
GitBud does not operate a relay or account service.

**Rationale.** The mobile apps should preserve the same no-server trust model as
the rest of GitKit.

**Status.** Accepted.
