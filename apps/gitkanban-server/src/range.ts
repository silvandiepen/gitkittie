export interface ByteRange {
  /** Inclusive start offset. */
  start: number;
  /** Inclusive end offset. */
  end: number;
}

export type RangeResult = { kind: "full" } | { kind: "partial"; range: ByteRange } | { kind: "unsatisfiable" };

/**
 * Parses a single `Range: bytes=a-b | a- | -n` header against a file of `size` bytes.
 * Missing, malformed, non-`bytes`, or multi-range headers yield `full` (serving the whole
 * representation is always permitted by RFC 9110). Syntactically valid but out-of-bounds
 * ranges yield `unsatisfiable`.
 */
export function parseRange(header: string | undefined, size: number): RangeResult {
  if (!header) {
    return { kind: "full" };
  }
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!match) {
    return { kind: "full" };
  }
  const [, startRaw = "", endRaw = ""] = match;
  if (startRaw === "" && endRaw === "") {
    return { kind: "full" };
  }

  if (startRaw === "") {
    // Suffix range: the last n bytes.
    const length = Number(endRaw);
    if (length === 0 || size === 0) {
      return { kind: "unsatisfiable" };
    }
    return { kind: "partial", range: { start: Math.max(0, size - length), end: size - 1 } };
  }

  const start = Number(startRaw);
  if (start >= size) {
    return { kind: "unsatisfiable" };
  }
  const end = endRaw === "" ? size - 1 : Math.min(Number(endRaw), size - 1);
  if (end < start) {
    return { kind: "full" };
  }
  return { kind: "partial", range: { start, end } };
}
