import { readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { parseReview } from '../src/index.js'
import { normalizeReview } from './vectors/normalize.js'

// Shared test vectors: each `<name>.md` is a review request and `<name>.json` what both
// parsers must read from it (the Swift side reads the same files in ReviewVectorTests).
// `UPDATE_REVIEW_VECTORS=1` rewrites the JSON from this parser: check the diff by hand.
const dir = join(import.meta.dirname, 'vectors', 'review')
const names = readdirSync(dir).filter((f) => f.endsWith('.md')).map((f) => f.slice(0, -3)).sort()

describe('shared review vectors', () => {
  it('has vectors', () => expect(names.length).toBeGreaterThan(0))
  for (const name of names) {
    it(name, () => {
      const actual = normalizeReview(parseReview(readFileSync(join(dir, `${name}.md`), 'utf8'), name))
      const jsonPath = join(dir, `${name}.json`)
      if (process.env.UPDATE_REVIEW_VECTORS) writeFileSync(jsonPath, JSON.stringify(actual, null, 2) + '\n')
      expect(actual).toEqual(JSON.parse(readFileSync(jsonPath, 'utf8')))
    })
  }
})
