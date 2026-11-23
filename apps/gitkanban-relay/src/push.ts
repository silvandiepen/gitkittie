// What a GitHub or GitLab push webhook says changed, reduced to what the apps need.
// The two payloads agree on `ref`, `after` and `commits[].added/modified/removed`.

/** The event the relay sends to subscribers. It carries paths, never file contents. */
export interface ChangeEvent {
  type: "push";
  /** The pushed ref, e.g. `refs/heads/main`. */
  ref: string;
  /** The commit the ref now points at. */
  head: string;
  /** Repo-relative paths that were added, modified or removed. */
  paths: string[];
  /**
   * False when the list cannot be trusted to be everything: both providers only list the
   * first commits of a large push, a force-push rewrites history, and the list is capped
   * here. A subscriber then reloads what it shows instead of patching. GitLab does not say
   * when a push was forced, so a forced GitLab push is reported like an ordinary one.
   */
  complete: boolean;
}

/** GitHub and GitLab both list at most this many commits in a push payload. */
const COMMIT_LIMIT = 20;
/** What `after` is when the branch was deleted. */
const NO_COMMIT = /^0+$/;
/** Enough for any ordinary push; beyond it a full reload is cheaper than the list. */
export const MAX_PATHS = 500;

interface PushCommit {
  added?: unknown;
  modified?: unknown;
  removed?: unknown;
}

function strings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];
}

/** The change event for a push payload, or `null` when the payload is not a usable push. */
export function changeEvent(payload: unknown): ChangeEvent | null {
  if (typeof payload !== "object" || payload === null) return null;
  const push = payload as {
    ref?: unknown;
    after?: unknown;
    forced?: unknown;
    commits?: unknown;
    deleted?: unknown;
    /** GitLab only: how many commits the push really had. */
    total_commits_count?: unknown;
  };
  if (typeof push.ref !== "string" || typeof push.after !== "string") return null;
  const commits: PushCommit[] = Array.isArray(push.commits) ? push.commits : [];
  const paths = new Set<string>();
  for (const commit of commits) {
    for (const path of [...strings(commit.added), ...strings(commit.modified), ...strings(commit.removed)]) {
      paths.add(path);
    }
  }
  const all = [...paths];
  const truncated = typeof push.total_commits_count === "number" && push.total_commits_count > commits.length;
  const complete =
    push.forced !== true &&
    push.deleted !== true &&
    !NO_COMMIT.test(push.after) &&
    !truncated &&
    commits.length < COMMIT_LIMIT &&
    all.length <= MAX_PATHS;
  return { type: "push", ref: push.ref, head: push.after, paths: all.slice(0, MAX_PATHS), complete };
}
