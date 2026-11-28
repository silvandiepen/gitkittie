// Which review requests a push made newly need an answer, and how loudly to say so.
//
// A request is `<board folder>/review/<request>/review.md`. For each one a push added or
// changed, the relay reads the file as it was before the push and as it is after, and
// announces it when something now waits for the reviewer that did not before: a new item
// without a decision, or a new question without an answer. Comparing the two versions
// means nothing has to be remembered between pushes.

import { parseReview, waitingEntries, type ReviewNotify } from "@gitkittie/gitkanban-core";
import type { Fetch } from "./apns.js";
import { fileAt, installationToken, type GitHubAppConfig } from "./github.js";

/** What a push notification about a review says. No file contents beyond the title. */
export interface ReviewAlert {
  /** `owner/name`. */
  repo: string;
  /** `Morrow/review/MORROW-182-pet-models/review.md`. */
  path: string;
  /** The request's folder, `Morrow/review/MORROW-182-pet-models`. */
  folder: string;
  /** The request's id from its frontmatter. */
  id: string;
  /** The board's name: the last part of its folder. */
  board: string;
  title: string;
  level: ReviewNotify;
}

const REVIEW_FILE = /^((?:[^/]+\/)*?([^/]+))\/review\/([^/]+)\/review\.md$/;
/** A push that touches more review requests than this is a bulk change (an import), not a request. */
export const MAX_REVIEWS_PER_PUSH = 10;
const NO_COMMIT = /^0+$/;

interface PushPayload {
  ref?: unknown;
  before?: unknown;
  after?: unknown;
  deleted?: unknown;
  commits?: unknown;
  repository?: { full_name?: unknown; id?: unknown; default_branch?: unknown };
  installation?: { id?: unknown };
}

/** The parts of a push the relay acts on, or `null` when it is not a push to the default branch. */
export interface ReviewPush {
  repo: string;
  repoID: number;
  installationID: number | null;
  /** The commit before the push, or `null` for a new branch. */
  before: string | null;
  after: string;
  /** Review files added or modified (and not removed again) by the push. */
  paths: string[];
}

function strings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];
}

export function reviewPush(payload: unknown): ReviewPush | null {
  if (typeof payload !== "object" || payload === null) return null;
  const push = payload as PushPayload;
  const repo = push.repository?.full_name;
  const repoID = push.repository?.id;
  const branch = push.repository?.default_branch;
  if (typeof repo !== "string" || typeof repoID !== "number" || typeof push.after !== "string") return null;
  // Reviews are read from the default branch, as the apps read the board.
  if (typeof branch !== "string" || push.ref !== `refs/heads/${branch}`) return null;
  if (push.deleted === true || NO_COMMIT.test(push.after)) return null;
  const touched = new Set<string>();
  const commits = Array.isArray(push.commits) ? (push.commits as Array<Record<string, unknown>>) : [];
  for (const commit of commits) {
    for (const path of [...strings(commit.added), ...strings(commit.modified)]) touched.add(path);
    for (const path of strings(commit.removed)) touched.delete(path);
  }
  const paths = [...touched].filter((path) => REVIEW_FILE.test(path)).slice(0, MAX_REVIEWS_PER_PUSH);
  const before = typeof push.before === "string" && !NO_COMMIT.test(push.before) ? push.before : null;
  const installation = push.installation?.id;
  return { repo, repoID, installationID: typeof installation === "number" ? installation : null, before, after: push.after, paths };
}

/**
 * The alert for a review file, given its text before the push (`null` when it did not exist)
 * and after; `null` when nothing newly waits for the reviewer.
 */
export function reviewAlert(repo: string, path: string, before: string | null, after: string): ReviewAlert | null {
  const match = REVIEW_FILE.exec(path);
  if (!match) return null;
  const [, , board, requestFolder] = match;
  const folder = path.slice(0, -"/review.md".length);
  const now = parseReview(after, requestFolder);
  const waiting = waitingEntries(now);
  if (waiting.length === 0) return null;
  const was = before === null ? new Set<string>() : new Set(waitingEntries(parseReview(before, requestFolder)));
  if (!waiting.some((entry) => !was.has(entry))) return null;
  return { repo, path, folder, id: now.id, board: board!, title: now.title, level: now.notify };
}


/**
 * Read each review file a push touched (before and after) as the GitHub App, and return the
 * alerts to send. File text stays in this function: only the alerts leave it.
 */
export async function alertsForPush(push: ReviewPush, config: GitHubAppConfig, fetcher: Fetch, now: number): Promise<ReviewAlert[]> {
  if (push.paths.length === 0 || push.installationID === null) return [];
  const token = await installationToken(config, push.installationID, push.repoID, fetcher, now);
  if (!token) return [];
  const alerts: ReviewAlert[] = [];
  for (const path of push.paths) {
    const after = await fileAt(token, push.repo, path, push.after, fetcher);
    if (after === null) continue;
    const before = push.before === null ? null : await fileAt(token, push.repo, path, push.before, fetcher);
    const alert = reviewAlert(push.repo, path, before, after);
    if (alert) alerts.push(alert);
  }
  return alerts;
}
