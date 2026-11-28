---
id: MAIL-030
title: "Threads link messages in one account by Message-ID, In-Reply-To and References only..."
date: 2026-11-24
status: proposed
---

# MAIL-030: Threads link messages in one account by Message-ID, In-Reply-To and References only...

**Decision.** Threads link messages in one account by Message-ID, In-Reply-To and References only (at most 100 per message); a Message-ID claimed by two different messages links nothing; the thread id is the group's smallest local id

**Why.** Never subject alone (Architecture.md); a forged or reused id cannot merge conversations; incremental and rebuilt threads are identical. GKM-012

**Links.** GKM-012
