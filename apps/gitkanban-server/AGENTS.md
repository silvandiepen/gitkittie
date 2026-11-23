# gitkanban-server — Agent Instructions

Read the repo root `AGENTS.md` first. This file adds what is specific to this app.

## What it is

A generic, safe remote filesystem over HTTP for **one** local folder, consumed by the
GitKanban iOS/macOS apps via Tailscale. The full API, config and security model are in
`README.md`; that API is a contract the Swift client is written against — change it only
together with the client, and update `README.md` in the same change.

## Hard boundaries

- **No git.** GitFolder syncs and commits the folder. Never add git operations here.
- **No board/review knowledge.** Parsing lives in the clients (`packages/gitkanban-core`
  and its Swift mirror). This server only lists, reads, writes, deletes and watches files.
- **Security is not optional.** Every route that takes a `path` goes through
  `src/paths.ts` (`resolveExisting` / `resolveForWrite`). Dot-paths and `node_modules` are
  never listed, served or written. Default bind stays `127.0.0.1`. Never use Funnel.

## Layout

| Module | Responsibility |
|---|---|
| `src/index.ts` | Start: load config, bind, graceful shutdown |
| `src/app.ts` | `createApp(config, options)` — all routes; pure apart from the served FS |
| `src/config.ts` | `GKS_*` env parsing |
| `src/paths.ts` | Path validation + realpath containment |
| `src/files.ts` | Listing, atomic write, delete, per-path locks |
| `src/watcher.ts` | One shared debounced recursive `fs.watch` for SSE |
| `src/etag.ts`, `src/range.ts`, `src/mime.ts`, `src/headers.ts` | Small HTTP helpers |
| `tools/` | `install-launchd.sh`, `tailscale-serve.sh` |

## Testing

`npm test -w @gitkittie/gitkanban-server` — vitest against Hono's `app.request()` and
**real temp directories**. Never mock the filesystem. Security behaviour (traversal,
dot-paths, symlink escapes, login allowlist) must stay covered.

## Style

2-space indent, double quotes, semicolons, strict TS, named exports (root `AGENTS.md`).
