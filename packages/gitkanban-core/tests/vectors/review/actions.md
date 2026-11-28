---
config: review
id: PETS-2-site
card: PETS-2
title: Site, round 2
requested_by: claude
on_accept: { to: testing }
on_changes:
  to: in-progress
  comment: true
  assign: claude
on_reject:
  - { to: todo, comment: yes }
  - { move: PETS-9, to: done }
  - { comment: true }
items:
  - id: hero-a
    file: hero-a.png
    group: hero
    pick: one
    status: approved
    decided_by: sil
    decided_at: 2026-11-30T10:00:00Z
  - id: hero-b
    file: hero-b.png
    group: hero
    status: pending
  - id: hero-c
    file: hero-c.png
    group: hero
    status: rejected
  - id: badge
    file: badge.png
    status: changes-requested
    decided_by: sil
    decided_at: 2026-11-30T10:01:00Z
    on_accept: { move: PETS-40, to: testing }
    on_changes: [{ move: PETS-40, to: in-progress, comment: true }]
---
