import type { BigIntStats } from "node:fs";

/**
 * Strong ETag derived from file metadata: `"<size hex>-<mtime nanoseconds hex>"`.
 * Every write goes through an atomic rename, which produces a new mtime, so the
 * value changes whenever the content is replaced. Cheap: no file read needed.
 */
export function etagFor(stats: BigIntStats): string {
  return `"${stats.size.toString(16)}-${stats.mtimeNs.toString(16)}"`;
}

/**
 * Whether an `If-None-Match` / `If-Match` header value matches `etag`.
 * Handles `*`, comma-separated lists, and tolerates `W/` prefixes (weak comparison
 * for If-None-Match, as RFC 9110 specifies).
 */
export function etagMatches(header: string, etag: string): boolean {
  return header
    .split(",")
    .map((candidate) => candidate.trim())
    .some((candidate) => candidate === "*" || candidate.replace(/^W\//, "") === etag);
}
