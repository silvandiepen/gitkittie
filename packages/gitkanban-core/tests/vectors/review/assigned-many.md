---
config: review
id: PETS-5-copy
title: Copy
for: [sil, herma, sil]
due: not a day
questions:
  - id: q
    question: Ok?
    options: [yes]
    answer: [yes]
    answered_by: herma
    answered_at: 2026-11-30T10:00:00Z
on_accept: { to: testing }
actions_run:
  - on: changes
    entry: null
    card: PETS-5
    from: in-review
    to: in-progress
    result: moved
    reason: null
    by: sil
    at: 2026-11-30T10:12:04Z
    undone_at: 2026-11-30T10:12:09Z
    before: { assignee: claude, reviewer: null }
  - { on: accept, entry: hero, card: PETS-6, to: testing, result: skipped, reason: "claimed by herma", by: sil, at: 2026-11-30T10:13:00Z }
  - { on: sideways, card: PETS-6, to: testing }
  - { on: accept, card: PETS-6, to: testing, result: weird }
---
