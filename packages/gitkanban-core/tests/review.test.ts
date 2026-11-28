import { describe, expect, it } from 'vitest'
import {
  appendActionRun,
  appendCheckComment,
  appendReviewComment,
  applyCheckAnswer,
  applyCheckDecision,
  applyCheckScreenshot,
  checkFailures,
  checklistID,
  checkScreenshotPath,
  isLocalOnlyURL,
  isReviewFor,
  markActionRunUndone,
  parseCheckSize,
  ReviewCheckNotFoundError,
  reviewOutcome,
  type ActionRun,
  applyReviewAnswer,
  applyReviewDecision,
  isQuestionAnswered,
  kindForFile,
  parseReview,
  resolveEffectiveConfig,
  resolveReviewPath,
  reviewAssetPath,
  ReviewItemNotFoundError,
  ReviewQuestionNotFoundError,
  summarizeReview,
  waitingEntries,
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

  it('reads notify, normal when absent or unknown', () => {
    expect(parseReview(REVIEW).notify).toBe('normal')
    expect(parseReview('---\nnotify: urgent\n---\n').notify).toBe('urgent')
    expect(parseReview('---\nnotify: Silent\n---\n').notify).toBe('silent')
    expect(parseReview('---\nnotify: loud\n---\n').notify).toBe('normal')
  })

  it('lists what still waits for the reviewer', () => {
    expect(waitingEntries(parseReview(REVIEW))).toEqual(['item:dog-v1'])
    const questions = parseReview(
      '---\nquestions:\n  - id: q1\n    question: A?\n    options: [a, b]\n  - id: q2\n    question: B?\n    options: [a]\n    answer: [a]\n    answered_at: 2026-11-08T15:00:00Z\n---\n',
    )
    expect(waitingEntries(questions)).toEqual(['question:q1'])
  })

  it('summarizes', () => {
    expect(summarizeReview(parseReview(REVIEW))).toEqual({
      total: 3, pending: 1, approved: 1, rejected: 1, changesRequested: 0, awaitingAgent: 1, questions: 0, answered: 0, checks: 0,
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

const QUESTIONS = `---
config: review
id: GKM-001-mail-decisions
agent_only_key: keep me
questions:
  - id: providers
    question: Which providers at first release?
    detail: "**Gmail** needs verification."
    select: one
    other: true
    options:
      - id: icloud
        label: iCloud only
        detail: Smallest scope.
      - id: imap
        label: iCloud and IMAP
    answer: []
    answer_other:
    comments: []
  - id: platforms
    question: Where?
    select: many
    options:
      - mac
      - id: ios
        label: iPhone
    answer: [ios, mac, nope]
    answered_by: sil
    answered_at: 2026-11-24T12:00:00Z
---

Notes.
`

describe('questions', () => {
  it('parses questions and counts them as waiting until answered', () => {
    const review = parseReview(QUESTIONS)
    expect(review.items).toEqual([])
    expect(review.questions.map((q) => q.id)).toEqual(['providers', 'platforms'])
    const [providers, platforms] = review.questions
    expect(providers.select).toBe('one')
    expect(providers.other).toBe(true)
    expect(providers.options[0]).toEqual({ id: 'icloud', label: 'iCloud only', detail: 'Smallest scope.' })
    expect(isQuestionAnswered(providers)).toBe(false)
    expect(platforms.options[0]).toEqual({ id: 'mac', label: 'mac' })
    expect(platforms.answer).toEqual(['mac', 'ios'])
    expect(isQuestionAnswered(platforms)).toBe(true)
    expect(summarizeReview(review)).toEqual({
      total: 2, pending: 1, approved: 0, rejected: 0, changesRequested: 0, awaitingAgent: 1, questions: 2, answered: 1, checks: 0,
    })
  })

  it('records an answer, enforcing one choice and keeping the rest', () => {
    const base = { questionId: 'providers', by: 'sil', at: '2026-11-24T13:00:00Z' }
    expect(() => applyReviewAnswer(QUESTIONS, { ...base, choices: ['icloud', 'imap'] })).toThrow(/one answer/)
    expect(() => applyReviewAnswer(QUESTIONS, { ...base, choices: ['icloud'], other: 'Fastmail' })).toThrow(/one answer/)
    expect(() => applyReviewAnswer(QUESTIONS, { ...base, choices: ['outlook'] })).toThrow(/not an option/)
    expect(() => applyReviewAnswer(QUESTIONS, { ...base, choices: [] })).toThrow(/Choose/)
    expect(() => applyReviewAnswer(QUESTIONS, { ...base, questionId: 'nope', choices: [] })).toThrow(ReviewQuestionNotFoundError)
    expect(() => applyReviewAnswer(QUESTIONS, { ...base, questionId: 'platforms', choices: ['mac'], other: 'Web' })).toThrow(/own/)

    const next = applyReviewAnswer(QUESTIONS, { ...base, choices: ['imap'], comment: 'Gmail later' })
    const q = parseReview(next).questions[0]
    expect(q.answer).toEqual(['imap'])
    expect(q.answeredBy).toBe('sil')
    expect(q.comments.map((c) => c.text)).toEqual(['Gmail later'])
    expect(parseReview(next).questions[1]).toEqual(parseReview(QUESTIONS).questions[1])
    expect(next).toContain('agent_only_key: keep me')

    const own = applyReviewAnswer(next, { ...base, choices: [], other: ' Fastmail ' })
    expect(parseReview(own).questions[0].answer).toEqual([])
    expect(parseReview(own).questions[0].answerOther).toBe('Fastmail')
  })
})

describe('browser checks and actions', () => {
  const CHECK = `---
id: PETS-3
title: Page
for: [sil]
on_accept: { to: testing }
checks:
  - id: page
    url: https://example.com
    sizes: [phone]
    checklist:
      - { id: hero, text: Headline fits }
    status: pending
---
`

  it('answers a line per size, keeping the rest', () => {
    let text = applyCheckAnswer(CHECK, { checkId: 'page', key: 'phone', line: 'hero', result: 'fail', note: ' Wraps ', by: 'sil', at: '2026-11-30T10:00:00Z', viewport: '402x874' })
    let check = parseReview(text).checks[0]
    expect(check.results.phone).toEqual({ viewport: '402x874', by: 'sil', at: '2026-11-30T10:00:00Z', answers: { hero: { result: 'fail', note: 'Wraps', at: '2026-11-30T10:00:00Z' } } })
    expect(checkFailures(check)).toEqual([{ size: 'phone', item: 'hero', text: 'Headline fits', result: 'fail', note: 'Wraps' }])
    expect(parseReview(text).actions.accept).toEqual([{ to: 'testing', comment: false }])
    text = applyCheckAnswer(text, { checkId: 'page', key: 'phone', line: 'hero', result: null, by: 'sil', at: '2026-11-30T10:01:00Z' })
    check = parseReview(text).checks[0]
    expect(check.results.phone.answers).toEqual({})
    expect(() => applyCheckAnswer(CHECK, { checkId: 'page', key: 'phone', line: 'hero', result: 'note', by: 'sil', at: 'x' })).toThrow()
    expect(() => applyCheckAnswer(CHECK, { checkId: 'page', key: 'phone', line: 'nope', result: 'pass', by: 'sil', at: 'x' })).toThrow()
    expect(() => applyCheckAnswer(CHECK, { checkId: 'gone', key: 'phone', line: 'hero', result: 'pass', by: 'sil', at: 'x' })).toThrow(ReviewCheckNotFoundError)
  })

  it('decides a check and gives the request an outcome', () => {
    const before = parseReview(CHECK)
    expect(waitingEntries(before)).toEqual(['check:page'])
    expect(waitingEntries(before, 'herma')).toEqual([])
    expect(reviewOutcome(before)).toBeNull()
    const text = applyCheckDecision(CHECK, { checkId: 'page', status: 'approved', by: 'sil', at: '2026-11-30T10:02:00Z' })
    const after = parseReview(text)
    expect(after.checks[0]).toMatchObject({ status: 'approved', decidedBy: 'sil' })
    expect(reviewOutcome(after)).toBe('accept')
    const commented = appendCheckComment(text, 'page', { by: 'sil', at: '2026-11-30T10:03:00Z', text: 'Fine' })
    expect(parseReview(commented).checks[0].comments).toEqual([{ by: 'sil', at: '2026-11-30T10:03:00Z', text: 'Fine' }])
    const shot = applyCheckScreenshot(text, { checkId: 'page', key: 'phone', path: checkScreenshotPath('page', 'phone'), by: 'sil', at: 'x' })
    expect(parseReview(shot).checks[0].results.phone.screenshot).toBe('results/page-phone.png')
  })

  it('appends action runs and marks one undone', () => {
    const run: ActionRun = { on: 'accept', card: 'PETS-3', from: 'in-review', to: 'testing', result: 'moved', by: 'sil', at: '2026-11-30T10:02:00Z', before: { reviewer: null } }
    const text = appendActionRun(CHECK, run)
    expect(parseReview(text).actionsRun).toEqual([run])
    const undone = markActionRunUndone(text, 0, '2026-11-30T10:02:05Z')
    expect(parseReview(undone).actionsRun[0].undoneAt).toBe('2026-11-30T10:02:05Z')
    expect(() => markActionRunUndone(text, 3, 'x')).toThrow()
  })

  it('knows sizes and local-only addresses', () => {
    expect(parseCheckSize('wide')).toEqual({ id: 'wide', label: 'Wide', width: 1920, height: 1080, ua: 'desktop' })
    expect(checklistID('The download button shows!')).toBe('the-download-button-shows')
    expect(isLocalOnlyURL('http://localhost:5173/x')).toBe(true)
    expect(isLocalOnlyURL('http://mac.local/')).toBe(true)
    expect(isLocalOnlyURL('https://preview.example.app')).toBe(false)
    expect(isReviewFor({ for: [] }, null)).toBe(true)
    expect(isReviewFor({ for: ['Sil'] }, 'sil')).toBe(true)
    expect(isReviewFor({ for: ['sil'] }, null)).toBe(false)
  })
})
