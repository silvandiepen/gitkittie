import { randomBytes } from "node:crypto";
import { mkdir, open, readdir, realpath, rename, stat, unlink } from "node:fs/promises";
import { basename, dirname, join, sep } from "node:path";
import { etagFor } from "./etag.js";
import { HttpError, errnoCode } from "./errors.js";
import { isHiddenName, isHiddenRelPath, type ResolvedPath, type WriteTarget } from "./paths.js";

export interface ListEntry {
  name: string;
  path: string;
  kind: "file" | "directory";
  size: number;
  mtime: string;
}

/**
 * Lists a directory's visible entries, sorted by name. Hidden names are skipped, as are
 * symlinks that are broken or point outside the root / onto a hidden path, and anything
 * that is neither a file nor a directory.
 */
export async function listDirectory(rootReal: string, dir: ResolvedPath): Promise<ListEntry[]> {
  const dirStats = await stat(dir.real);
  if (!dirStats.isDirectory()) {
    throw new HttpError(400, "not_a_directory", `"${dir.rel}" is not a directory.`);
  }
  const dirents = await readdir(dir.real, { withFileTypes: true });
  const entries: ListEntry[] = [];
  for (const dirent of dirents) {
    if (isHiddenName(dirent.name)) {
      continue;
    }
    const absolute = join(dir.real, dirent.name);
    if (dirent.isSymbolicLink() && !(await symlinkStaysInside(rootReal, absolute))) {
      continue;
    }
    let entryStats;
    try {
      entryStats = await stat(absolute);
    } catch (error) {
      // Deleted between readdir and stat: it's simply no longer part of the listing.
      if (errnoCode(error) === "ENOENT") {
        continue;
      }
      throw error;
    }
    const kind = entryStats.isDirectory() ? "directory" : entryStats.isFile() ? "file" : null;
    if (!kind) {
      continue;
    }
    entries.push({
      name: dirent.name,
      path: dir.rel === "" ? dirent.name : `${dir.rel}/${dirent.name}`,
      kind,
      size: kind === "file" ? entryStats.size : 0,
      mtime: entryStats.mtime.toISOString(),
    });
  }
  return entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
}

async function symlinkStaysInside(rootReal: string, absolute: string): Promise<boolean> {
  let real: string;
  try {
    real = await realpath(absolute);
  } catch (error) {
    if (errnoCode(error) === "ENOENT") {
      return false;
    }
    throw error;
  }
  if (!real.startsWith(rootReal + sep)) {
    return false;
  }
  return !isHiddenRelPath(real.slice(rootReal.length + 1).split(sep).join("/"));
}

/** Current strong ETag of a path, or `null` if nothing is there. 400 if it's a directory. */
export async function currentEtag(target: string): Promise<string | null> {
  try {
    const stats = await stat(target, { bigint: true });
    if (!stats.isFile()) {
      throw new HttpError(400, "not_a_file", "Path is not a file.");
    }
    return etagFor(stats);
  } catch (error) {
    if (errnoCode(error) === "ENOENT") {
      return null;
    }
    throw error;
  }
}

/**
 * Serialises mutations per absolute path so a precondition check and the rename that
 * follows it can't interleave with another request for the same file.
 */
export class PathLocks {
  private readonly tails = new Map<string, Promise<void>>();

  async run<T>(key: string, task: () => Promise<T>): Promise<T> {
    const previous = this.tails.get(key) ?? Promise.resolve();
    let release!: () => void;
    const current = new Promise<void>((resolve) => {
      release = resolve;
    });
    const tail = previous.then(() => current);
    this.tails.set(key, tail);
    await previous;
    try {
      return await task();
    } finally {
      release();
      if (this.tails.get(key) === tail) {
        this.tails.delete(key);
      }
    }
  }
}

/**
 * Streams `body` into a dot-prefixed temp file beside `target` (so it's invisible to
 * listings and the watcher), fsyncs it, then renames it over the target. Creates parent
 * directories. Enforces `limitBytes` while streaming (413). Returns the new ETag.
 */
export async function writeFileAtomic(
  target: WriteTarget,
  body: ReadableStream<Uint8Array> | null,
  limitBytes: number,
): Promise<string> {
  const dir = dirname(target.target);
  try {
    await mkdir(dir, { recursive: true });
  } catch (error) {
    const code = errnoCode(error);
    if (code === "EEXIST" || code === "ENOTDIR") {
      throw new HttpError(409, "not_a_directory", "A parent of this path is a file.");
    }
    throw error;
  }

  let mode = 0o644;
  if (target.exists) {
    mode = (await stat(target.target)).mode & 0o7777;
  }

  const temp = join(dir, `.gks-${basename(target.target)}-${randomBytes(6).toString("hex")}.tmp`);
  const handle = await open(temp, "wx", mode);
  let closed = false;
  let renamed = false;
  try {
    let written = 0;
    if (body) {
      for await (const chunk of body) {
        written += chunk.byteLength;
        if (written > limitBytes) {
          throw new HttpError(413, "payload_too_large", `Body exceeds ${limitBytes} bytes.`);
        }
        await handle.write(chunk);
      }
    }
    await handle.sync();
    closed = true;
    await handle.close();
    await rename(temp, target.target);
    renamed = true;
  } finally {
    if (!closed) {
      await handle.close();
    }
    if (!renamed) {
      await unlink(temp);
    }
  }
  return etagFor(await stat(target.target, { bigint: true }));
}

/** Deletes a file (never a directory). 404 if it doesn't exist. */
export async function deleteFile(target: WriteTarget): Promise<void> {
  if (!target.exists) {
    throw new HttpError(404, "not_found", `No such path "${target.rel}".`);
  }
  const stats = await stat(target.target);
  if (!stats.isFile()) {
    throw new HttpError(400, "not_a_file", "Only files can be deleted.");
  }
  await unlink(target.target);
}
