import { describe, expect, it } from 'vitest'
import { isUnread, latestActivity, stageForLane } from '../src/progress.js'
import type { Lane } from '../src/types.js'

const lane = (id: string, name: string, terminal?: boolean): Lane =>
  ({ id, name, folder: name, status: id, ...(terminal ? { terminal } : {}) }) as Lane

describe('stageForLane', () => {
  const lanes = [
    lane('todo', '1. To do'),
    lane('in-progress', '2. In Progress'),
    lane('in-review', '3. In Review'),
    lane('testing', '4. Testing'),
    lane('done', '5. Done', true),
  ]

  it('splits the board around the in-progress lane', () => {
    expect(lanes.map((l) => stageForLane(l, lanes))).toEqual(['pipeline', 'working', 'checkedOff', 'checkedOff', 'checkedOff'])
  })

  it('falls back to first = pipeline, last = checked off without a progress lane', () => {
    const custom = [lane('idea', 'Ideas'), lane('draft', 'Drafting'), lane('shipped', 'Shipped')]
    expect(custom.map((l) => stageForLane(l, custom))).toEqual(['pipeline', 'working', 'checkedOff'])
  })

  it('always treats terminal lanes as checked off', () => {
    const odd = [lane('won', 'Won', true), lane('doing', 'Doing')]
    expect(stageForLane(odd[0]!, odd)).toBe('checkedOff')
    expect(stageForLane(odd[1]!, odd)).toBe('working')
  })
})

describe('isUnread', () => {
  it('is unread until read, and again after a later update', () => {
    expect(isUnread({})).toBe(true)
    expect(isUnread({ read_at: '2026-11-08T10:00:00Z', updated_at: '2026-11-08T09:00:00Z' })).toBe(false)
    expect(isUnread({ read_at: '2026-11-08T10:00:00Z' })).toBe(false)
    expect(isUnread({ read_at: '2026-11-08T10:00:00Z', updated_at: '2026-11-08T11:00:00Z' })).toBe(true)
    expect(isUnread({ read_at: new Date('2026-11-08T10:00:00Z'), updated_at: new Date('2026-11-08T10:00:00Z') })).toBe(false)
  })
})

describe('latestActivity', () => {
  it('returns the last entry of the Activity log', () => {
    const body = '# T\n\n## Activity log\n\n- 2026-11-08T10:00:00Z — created\n- 2026-11-08T11:00:00Z — `claude` moved it to In Review\n\n## Notes\n- not this\n'
    expect(latestActivity(body)).toBe('2026-11-08T11:00:00Z — `claude` moved it to In Review')
    expect(latestActivity('# T\n\nno log')).toBeUndefined()
  })
})
