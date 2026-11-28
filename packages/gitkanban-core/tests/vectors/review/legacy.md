---
config: review
id: PETS-1-models
project: Pets
card: PETS-1
title: Pet models, round 1
question: Pick one dog.
requested_by: claude
requested_at: 2026-11-08T14:00:00Z
agent_only_key: keep me
items:
  - id: dog-v1
    file: dog-v1.usdz
    preview: dog-v1.png
    group: dog
    pick: one
    status: pending
    comments: []
  - id: dog-v2
    file: dog-v2.usdz
    group: dog
    status: approved
    decided_by: sil
    decided_at: 2026-11-08T15:00:00Z
    comments:
      - by: sil
        at: 2026-11-08T15:00:00Z
        text: Ears are right now
  - id: bark
    file: sounds/bark.m4a
    status: rejected
    handled_at: 2026-11-08T16:00:00Z
questions:
  - id: tone
    question: Which tone?
    options: [calm, bold]
---

Notes.
