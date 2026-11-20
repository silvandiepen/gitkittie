import { describe, expect, it } from 'vitest'
import {
  appendReviewComment,
  applyReviewDecision,
  kindForFile,
  parseReview,
  resolveEffectiveConfig,
  resolveReviewPath,
  reviewAssetPath,
  ReviewItemNotFoundError,
  summarizeReview,
} from '../src/index.js'

const REVIEW = `---
config: review
id: MORROW-182-pet-models
project: Morrow
card: MORROW-182
title: Pet models, round 1
question: Pick one dog.
requested_by: claude
requested_at: 2026-11-08T14:00:00Z
agent_only_key: keep me
items:
  - id: dog-v1
    file: dog-v1.usdz
    preview: dog-v1.png
    kind: model
    group: dog
    pick: one
    note: 2600 faces
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
---

Made with Tripo, ~40 credits.
`

describe('parseReview', () => {
  it('parses the request and its items', () => {
    const review = parseReview(REVIEW)
    expect(review.id).toBe('MORROW-182-pet-models')
    expect(review.card).toBe('MORROW-182')
    expect(review.question).toBe('Pick one dog.')
    expect(review.requestedAt).toBe('2026-11-08T14:00:00Z')
    expect(review.items.map((i) => i.id)).toEqual(['dog-v1', 'dog-v2', 'bark'])
    expect(review.items[0]).toMatchObject({ kind: 'model', group: 'dog', pick: 'one', preview: 'dog-v1.png', status: 'pending' })
    expect(review.items[1].comments).toEqual([{ by: 'sil', at: '2026-11-08T15:00:00Z', text: 'Ears are right now' }])
    expect(review.items[2].kind).toBe('audio')
    expect(review.body.trim()).toBe('Made with Tripo, ~40 credits.')
  })

  it('falls back to the folder id and pending for unknown status', () => {
    const review = parseReview('---\nitems:\n  - file: a.png\n    status: maybe\n  - note: no file\n---\n', 'folder-id')
    expect(review.id).toBe('folder-id')
    expect(review.title).toBe('folder-id')
    expect(review.items).toHaveLength(1)
    expect(review.items[0]).toMatchObject({ id: 'item-1', kind: 'image', status: 'pending' })
  })

  it('summarizes', () => {
    expect(summarizeReview(parseReview(REVIEW))).toEqual({
      total: 3, pending: 1, approved: 1, rejected: 1, changesRequested: 0, awaitingAgent: 1,
    })
  })
})

describe('reviewer writes', () => {
  it('changes only the reviewer fields of one item', () => {
    const next = applyReviewDecision(REVIEW, { itemId: 'dog-v1', status: 'changes-requested', by: 'sil', at: '2026-11-08T17:00:00Z' })
    const review = parseReview(next)
    expect(review.items[0]).toMatchObject({ status: 'changes-requested', decidedBy: 'sil', decidedAt: '2026-11-08T17:00:00Z', note: '2600 faces' })
    expect(review.items[1]).toEqual(parseReview(REVIEW).items[1])
    expect(next).toContain('agent_only_key: keep me')
    expect(next).toContain('Made with Tripo, ~40 credits.')
  })

  it('clears the decision when set back to pending', () => {
    const next = applyReviewDecision(REVIEW, { itemId: 'dog-v2', status: 'pending', by: 'sil', at: 'x' })
    expect(parseReview(next).items[1]).toMatchObject({ status: 'pending', decidedBy: undefined, decidedAt: undefined })
  })

  it('appends comments without rewriting existing ones', () => {
    const next = appendReviewComment(REVIEW, 'dog-v2', { by: 'sil', at: '2026-11-08T18:00:00Z', text: '  Tail too long  ' })
    expect(parseReview(next).items[1].comments.map((c) => c.text)).toEqual(['Ears are right now', 'Tail too long'])
    expect(() => appendReviewComment(REVIEW, 'dog-v2', { by: 'sil', at: 'x', text: '   ' })).toThrow()
  })

  it('throws for an unknown item', () => {
    expect(() => applyReviewDecision(REVIEW, { itemId: 'nope', status: 'approved', by: 'sil', at: 'x' })).toThrow(ReviewItemNotFoundError)
  })
})

describe('paths', () => {
  it('resolves review_path relative to the project folder', () => {
    expect(resolveReviewPath('../../{folder}/review', 'Tasks/Morrow')).toBe('Morrow/review')
    expect(resolveReviewPath('review', 'Tasks/Morrow')).toBe('Tasks/Morrow/review')
    expect(resolveReviewPath(undefined, 'Tasks/Morrow')).toBeNull()
    expect(resolveReviewPath('../../../x', 'Tasks/Morrow')).toBeNull()
    expect(resolveReviewPath('/abs', 'Tasks/Morrow')).toBeNull()
  })

  it('resolves asset files inside the request folder', () => {
    expect(reviewAssetPath('Morrow/review/R1', 'dog.png')).toBe('Morrow/review/R1/dog.png')
    expect(reviewAssetPath('Morrow/review/R1', '../../art/dog.png')).toBe('Morrow/art/dog.png')
    expect(reviewAssetPath('Morrow/review/R1', '../../../../etc')).toBeNull()
  })

  it('inherits review_path from the root config', () => {
    const root = { lanes: [], users: [], epics: [], priorities: [], types: [], tags: [], reviewPath: '../../{folder}/review' }
    expect(resolveEffectiveConfig(root, {}).reviewPath).toBe('../../{folder}/review')
    expect(resolveEffectiveConfig(root, { reviewPath: 'review' }).reviewPath).toBe('review')
  })

  it('infers kinds from extensions', () => {
    expect(['a.PNG', 'b.usdz', 'c.wav', 'd.gif', 'e.mov', 'f.txt'].map(kindForFile)).toEqual(['image', 'model', 'audio', 'animation', 'video', 'other'])
  })
})
