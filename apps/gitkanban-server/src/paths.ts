import { lstat, realpath } from "node:fs/promises";
import { dirname, join, relative, sep } from "node:path";
import { HttpError, errnoCode } from "./errors.js";

/** Directory names never listed, served, or written (besides any dot-segment). */
const HIDDEN_NAMES = new Set(["node_modules"]);

/** True for names that are never exposed: dotfiles/dot-dirs and `node_modules`. */
export function isHiddenName(name: string): boolean {
  return name.startsWith(".") || HIDDEN_NAMES.has(name);
}

/** True if any segment of a root-relative, forward-slash path is hidden. */
export function isHiddenRelPath(relPath: string): boolean {
  return relPath.split("/").some((segment) => segment.length > 0 && isHiddenName(segment));
}

/**
 * Validates a client-supplied root-relative path and returns its segments.
 * `""` (or `undefined`) is the root and yields `[]`.
 * - 400 for `..`, absolute paths, NUL bytes, backslashes, empty segments.
 * - 403 for any segment that is hidden (starts with `.`, or is `node_modules`).
 */
export function parseRelPath(input: string | undefined): string[] {
  const raw = input ?? "";
  if (raw === "") {
    return [];
  }
  if (raw.includes("\0")) {
    throw new HttpError(400, "invalid_path", "Path contains a NUL byte.");
  }
  if (raw.includes("\\")) {
    throw new HttpError(400, "invalid_path", "Path contains a backslash.");
  }
  if (raw.startsWith("/")) {
    throw new HttpError(400, "invalid_path", "Path must be root-relative, not absolute.");
  }
  const trimmed = raw.endsWith("/") ? raw.slice(0, -1) : raw;
  const segments = trimmed.split("/");
  for (const segment of segments) {
    if (segment === "" || segment === "." || segment === "..") {
      throw new HttpError(400, "invalid_path", `Invalid path segment "${segment}".`);
    }
  }
  if (segments.some(isHiddenName)) {
    throw new HttpError(403, "forbidden_path", "Hidden paths are not accessible.");
  }
  return segments;
}

/** Root-relative forward-slash form of an absolute path known to be inside `rootReal`. */
function toRel(rootReal: string, absolute: string): string {
  return relative(rootReal, absolute).split(sep).join("/");
}

/** Throws 403 unless `realTarget` is `rootReal` itself or lies inside it on a non-hidden path. */
function assertContained(rootReal: string, realTarget: string): void {
  if (realTarget !== rootReal && !realTarget.startsWith(rootReal + sep)) {
    throw new HttpError(403, "forbidden_path", "Path resolves outside the served root.");
  }
  if (isHiddenRelPath(toRel(rootReal, realTarget))) {
    throw new HttpError(403, "forbidden_path", "Path resolves to a hidden location.");
  }
}

export interface ResolvedPath {
  /** Normalised root-relative path as the client should see it (`""` = root). */
  rel: string;
  /** Absolute, symlink-resolved path on disk. */
  real: string;
}

/**
 * Resolves an existing path for reading. 404 if it doesn't exist (including broken
 * symlinks), 403 if its realpath escapes the root or lands on a hidden path.
 */
export async function resolveExisting(rootReal: string, input: string | undefined): Promise<ResolvedPath> {
  const segments = parseRelPath(input);
  const rel = segments.join("/");
  let real: string;
  try {
    real = await realpath(join(rootReal, ...segments));
  } catch (error) {
    const code = errnoCode(error);
    if (code === "ENOENT" || code === "ENOTDIR") {
      throw new HttpError(404, "not_found", `No such path "${rel}".`);
    }
    throw error;
  }
  assertContained(rootReal, real);
  return { rel, real };
}

export interface WriteTarget {
  rel: string;
  /** Absolute path to write to (parent directory realpath-resolved). */
  target: string;
  /** Whether something currently exists at `target`. */
  exists: boolean;
}

/**
 * Resolves a file path for writing or deleting. The root itself is never a valid target.
 * If the target exists, its realpath must be inside the root. Otherwise the nearest
 * existing ancestor's realpath must be inside the root, so a symlinked directory can't
 * redirect a create outside it.
 */
export async function resolveForWrite(rootReal: string, input: string | undefined): Promise<WriteTarget> {
  const segments = parseRelPath(input);
  if (segments.length === 0) {
    throw new HttpError(400, "invalid_path", "A file path is required.");
  }
  const rel = segments.join("/");
  const lexical = join(rootReal, ...segments);

  let exists = true;
  try {
    await lstat(lexical);
  } catch (error) {
    const code = errnoCode(error);
    if (code === "ENOENT") {
      exists = false;
    } else if (code === "ENOTDIR") {
      throw new HttpError(409, "not_a_directory", "A parent of this path is a file.");
    } else {
      throw error;
    }
  }

  if (exists) {
    let real: string;
    try {
      real = await realpath(lexical);
    } catch (error) {
      if (errnoCode(error) === "ENOENT") {
        // Dangling symlink: refuse rather than write through it to an unknown location.
        throw new HttpError(403, "forbidden_path", "Path is a dangling symlink.");
      }
      throw error;
    }
    assertContained(rootReal, real);
    return { rel, target: real, exists };
  }

  // Walk up to the nearest existing ancestor and check that one.
  let ancestor = dirname(lexical);
  const missing: string[] = [lexical.slice(ancestor.length + 1)];
  for (;;) {
    try {
      const realAncestor = await realpath(ancestor);
      assertContained(rootReal, realAncestor);
      return { rel, target: join(realAncestor, ...missing.reverse()), exists };
    } catch (error) {
      if (errnoCode(error) !== "ENOENT") {
        if (errnoCode(error) === "ENOTDIR") {
          throw new HttpError(409, "not_a_directory", "A parent of this path is a file.");
        }
        throw error;
      }
      if (ancestor === rootReal) {
        throw new HttpError(500, "root_missing", "The served root no longer exists.");
      }
      const parent = dirname(ancestor);
      missing.push(ancestor.slice(parent.length + 1));
      ancestor = parent;
    }
  }
}
