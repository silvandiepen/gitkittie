import { realpathSync } from "node:fs";
import { open } from "node:fs/promises";
import { basename } from "node:path";
import { Readable } from "node:stream";
import { Hono } from "hono";
import type { ServerConfig } from "./config.js";
import { etagFor, etagMatches } from "./etag.js";
import { HttpError } from "./errors.js";
import { PathLocks, currentEtag, deleteFile, listDirectory, writeFileAtomic } from "./files.js";
import { decodeHeaderWord } from "./headers.js";
import { contentTypeFor } from "./mime.js";
import { resolveExisting, resolveForWrite } from "./paths.js";
import { parseRange } from "./range.js";
import { SharedWatcher } from "./watcher.js";

export const MAX_UPLOAD_BYTES = 200 * 1024 * 1024;
export const PING_INTERVAL_MS = 25_000;

export interface AppOptions {
  /** Shared watcher for `/api/events`; created from the root when omitted. */
  watcher?: SharedWatcher;
  pingIntervalMs?: number;
  maxUploadBytes?: number;
}

const LOGIN_HEADER = "Tailscale-User-Login";
const NAME_HEADER = "Tailscale-User-Name";

/** Builds the HTTP app for one served root. Pure apart from the filesystem it serves. */
export function createApp(config: Pick<ServerConfig, "root" | "allowedLogins">, options: AppOptions = {}): Hono {
  const rootReal = realpathSync(config.root);
  const watcher = options.watcher ?? new SharedWatcher(rootReal);
  const pingIntervalMs = options.pingIntervalMs ?? PING_INTERVAL_MS;
  const maxUploadBytes = options.maxUploadBytes ?? MAX_UPLOAD_BYTES;
  const allowed = new Set(config.allowedLogins);
  const locks = new PathLocks();

  const app = new Hono();

  app.onError((error, c) => {
    if (error instanceof HttpError) {
      const body: Record<string, unknown> = { error: error.code, ...error.extra };
      if (error.message !== error.code) {
        body.message = error.message;
      }
      return c.json(body, error.status);
    }
    console.error("[gitkanban-server] unhandled error:", error);
    return c.json({ error: "internal" }, 500);
  });

  app.notFound((c) => c.json({ error: "not_found" }, 404));

  app.get("/api/health", (c) => c.json({ ok: true, root: basename(rootReal) }));

  app.use("/api/*", async (c, next) => {
    if (allowed.size > 0) {
      const login = c.req.header(LOGIN_HEADER)?.trim();
      if (!login || !allowed.has(login)) {
        return c.json({ error: "forbidden_login" }, 403);
      }
    }
    await next();
  });

  app.get("/api/whoami", (c) => {
    const login = c.req.header(LOGIN_HEADER)?.trim() || null;
    const name = c.req.header(NAME_HEADER)?.trim();
    return c.json({ login, name: name ? decodeHeaderWord(name) : null });
  });

  app.get("/api/list", async (c) => {
    const dir = await resolveExisting(rootReal, c.req.query("path"));
    return c.json(await listDirectory(rootReal, dir));
  });

  app.get("/api/file", async (c) => {
    const file = await resolveExisting(rootReal, c.req.query("path"));
    // Open first and fstat the handle, so headers and bytes describe the same file even
    // if it's replaced mid-request.
    const handle = await open(file.real, "r");
    let handedOff = false;
    try {
      const stats = await handle.stat({ bigint: true });
      if (!stats.isFile()) {
        throw new HttpError(400, "not_a_file", `"${file.rel}" is not a file.`);
      }
      const size = Number(stats.size);
      const etag = etagFor(stats);
      const headers = new Headers({
        "Content-Type": contentTypeFor(file.real),
        ETag: etag,
        "Last-Modified": stats.mtime.toUTCString(),
        "Accept-Ranges": "bytes",
        "Cache-Control": "no-cache",
      });

      const ifNoneMatch = c.req.header("If-None-Match");
      if (ifNoneMatch && etagMatches(ifNoneMatch, etag)) {
        return new Response(null, { status: 304, headers });
      }

      const range = parseRange(c.req.header("Range"), size);
      if (range.kind === "unsatisfiable") {
        headers.set("Content-Range", `bytes */${size}`);
        headers.set("Content-Type", "application/json; charset=utf-8");
        return new Response(JSON.stringify({ error: "range_not_satisfiable" }), { status: 416, headers });
      }

      const start = range.kind === "partial" ? range.range.start : 0;
      const end = range.kind === "partial" ? range.range.end : size - 1;
      const length = size === 0 ? 0 : end - start + 1;
      headers.set("Content-Length", String(length));
      const status = range.kind === "partial" ? 206 : 200;
      if (range.kind === "partial") {
        headers.set("Content-Range", `bytes ${start}-${end}/${size}`);
      }

      if (c.req.method === "HEAD" || length === 0) {
        return new Response(null, { status, headers });
      }
      const stream = handle.createReadStream({ start, end, autoClose: true });
      handedOff = true;
      return new Response(Readable.toWeb(stream) as ReadableStream<Uint8Array>, { status, headers });
    } finally {
      if (!handedOff) {
        await handle.close();
      }
    }
  });

  app.put("/api/file", async (c) => {
    const declared = Number(c.req.header("Content-Length") ?? "0");
    if (declared > maxUploadBytes) {
      throw new HttpError(413, "payload_too_large", `Body exceeds ${maxUploadBytes} bytes.`);
    }
    const target = await resolveForWrite(rootReal, c.req.query("path"));
    const ifMatch = c.req.header("If-Match");
    const ifNoneMatch = c.req.header("If-None-Match");
    return locks.run(target.target, async () => {
      const etag = await currentEtag(target.target);
      checkPreconditions(etag, ifMatch, ifNoneMatch);
      const fresh = { ...target, exists: etag !== null };
      const newEtag = await writeFileAtomic(fresh, c.req.raw.body, maxUploadBytes);
      return c.json({ etag: newEtag }, 200, { ETag: newEtag });
    });
  });

  app.delete("/api/file", async (c) => {
    const target = await resolveForWrite(rootReal, c.req.query("path"));
    const ifMatch = c.req.header("If-Match");
    return locks.run(target.target, async () => {
      const etag = await currentEtag(target.target);
      if (etag === null) {
        throw new HttpError(404, "not_found", `No such path "${target.rel}".`);
      }
      checkPreconditions(etag, ifMatch, undefined);
      await deleteFile({ ...target, exists: true });
      return c.body(null, 204);
    });
  });

  app.get("/api/events", (c) => {
    const encoder = new TextEncoder();
    const signal = c.req.raw.signal;
    let cleanup: () => void = () => undefined;

    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        let open = true;
        const send = (text: string): void => {
          if (open) {
            controller.enqueue(encoder.encode(text));
          }
        };
        const ping = setInterval(() => send(": ping\n\n"), pingIntervalMs);
        const unsubscribe = watcher.subscribe({
          onChange: (paths) => send(`event: change\ndata: ${JSON.stringify({ paths })}\n\n`),
          onClose: () => {
            if (open) {
              cleanup();
              controller.close();
            }
          },
        });
        const onAbort = (): void => {
          if (open) {
            cleanup();
            controller.close();
          }
        };
        cleanup = () => {
          if (!open) {
            return;
          }
          open = false;
          clearInterval(ping);
          unsubscribe();
          signal.removeEventListener("abort", onAbort);
        };
        signal.addEventListener("abort", onAbort);
        send("retry: 3000\n: connected\n\n");
      },
      cancel() {
        cleanup();
      },
    });

    return new Response(body, {
      headers: {
        "Content-Type": "text/event-stream; charset=utf-8",
        "Cache-Control": "no-cache, no-transform",
        "X-Accel-Buffering": "no",
      },
    });
  });

  return app;
}

/**
 * `If-Match` (any listed ETag must equal the current one; fails when the file is missing)
 * and `If-None-Match: *` (create-only; fails when the file exists). Either failure is 412
 * `{ "error": "conflict", "etag": <current or null> }`.
 */
function checkPreconditions(current: string | null, ifMatch: string | undefined, ifNoneMatch: string | undefined): void {
  if (ifMatch !== undefined) {
    const matches =
      current !== null &&
      ifMatch
        .split(",")
        .map((candidate) => candidate.trim())
        .some((candidate) => candidate === "*" || candidate === current);
    if (!matches) {
      throw new HttpError(412, "conflict", undefined, { etag: current });
    }
  }
  if (ifNoneMatch !== undefined && current !== null && etagMatches(ifNoneMatch, current)) {
    throw new HttpError(412, "conflict", undefined, { etag: current });
  }
}
