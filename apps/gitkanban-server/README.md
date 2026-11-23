# @gitkittie/gitkanban-server

A small, always-on file server that exposes **one** configured local folder (e.g.
`~/Projects`) to the GitKanban iOS/macOS apps over **Tailscale**.

- It does **no git operations**. The folder is kept in sync by another tool (GitFolder),
  which auto-commits.
- It knows nothing about boards or reviews. All parsing happens in the clients. It is a
  generic, safe remote filesystem: list, read, write, delete, watch.

Node 22, TypeScript (strict), [Hono](https://hono.dev) on `@hono/node-server`, ESM.

## Configuration

| Env var | Default | Meaning |
|---|---|---|
| `GKS_ROOT` | *(required)* | Absolute folder to serve. |
| `GKS_PORT` | `4417` | Port to listen on. |
| `GKS_HOST` | `127.0.0.1` | Interface to bind. Never defaults to `0.0.0.0`. |
| `GKS_ALLOWED_LOGINS` | *(unset)* | Comma-separated Tailscale logins. If set, every `/api/*` request except `/api/health` must carry `Tailscale-User-Login` with one of these values, else `403`. |
| `GKS_ANNOUNCE` | on | Set to `0` to stop announcing on Bonjour. |
| `GKS_PUBLIC_URL` | Tailscale HTTPS name | The address the apps are told to use. By default it is detected from `tailscale status --json`. |
| `GKS_NAME` | `<folder> on <computer name>` | The name shown in the apps. |

## HTTP API

All paths are root-relative, forward slashes, `""` = root, passed as query `path`.
Errors are JSON `{"error": "<code>", "message"?: "..."}`.

- `GET /api/health` → `{"ok":true,"root":"<basename of root>"}` (no auth needed).
- `GET /api/whoami` → `{"login": string|null, "name": string|null}` from
  `Tailscale-User-Login` / `Tailscale-User-Name` headers. (RFC 2047 encoded names, which
  Tailscale uses for non-ASCII, are decoded.)
- `GET /api/list?path=<dir>` → `200 [{"name","path","kind":"file"|"directory","size":number,"mtime":ISO string}]`.
  Skips dotfiles/dot-dirs (`.git`, `.DS_Store`, …) and `node_modules`. `404` if missing,
  `400` if not a directory. Entries are sorted by name; directories report `size: 0`;
  symlinks that are broken or resolve outside the root (or onto a hidden path) are omitted.
- `GET /api/file?path=<file>` → raw bytes, `Content-Type` by extension (see below), `ETag`,
  `Last-Modified`, `Accept-Ranges: bytes`, `Cache-Control: no-cache`. Supports a single
  `Range: bytes=a-b` / `a-` / `-n` → `206` with `Content-Range`; unsatisfiable → `416`
  (with `Content-Range: bytes */<size>`). Multi-range or malformed `Range` headers are
  ignored and the full file is served (`200`), as RFC 9110 allows. `If-None-Match` → `304`.
  Streams from disk. `HEAD` is supported. `400` for a directory, `404` if missing.
- `PUT /api/file?path=<file>` body = raw bytes. Optional `If-Match: <etag>`: if present and
  the file's current ETag differs (or the file doesn't exist) → `412`
  `{"error":"conflict","etag":"<current>"}` (`etag` is `null` when the file is missing).
  `If-None-Match: *` → `412` if the file exists (create-only). Creates parent directories.
  Writes atomically (temp file in the same dir, fsync, rename). Returns
  `200 {"etag": "<new>"}` (also as the `ETag` header). Body limit 200 MB → `413`.
  `400` if the path is a directory; `409` if a parent component is a file.
- `DELETE /api/file?path=<file>` (optional `If-Match` like PUT) → `204`. Files only, never
  directories (`400`). `404` if missing.
- `GET /api/events` → Server-Sent Events. One shared recursive `fs.watch` on the root
  (dot-paths and `node_modules` ignored), debounced 150 ms (and flushed at most 1 s after
  the first change during continuous churn), coalesced:

  ```
  event: change
  data: {"paths":["rel/path",...]}
  ```

  A `: ping` comment every 25 s. The stream opens with `retry: 3000` and `: connected`.
  The watcher starts with the first client and closes with the last. If the watcher
  errors, open streams are closed so clients reconnect.

### ETag format

Strong ETag from metadata, no content hashing: `"<size hex>-<mtime nanoseconds hex>"`,
e.g. `"419e-18cbb3f31f1cc0b3"`. Every server write is an atomic rename, which yields a new
mtime, so the tag changes whenever content is replaced. Clients must treat it as opaque.

### Content types

`png`, `jpg`/`jpeg`, `webp`, `gif`, `svg` (`image/svg+xml`), `md` →
`text/markdown; charset=utf-8`, `json` → `application/json; charset=utf-8`, `txt` →
`text/plain; charset=utf-8`, `usdz` → `model/vnd.usdz+zip`, `glb` → `model/gltf-binary`,
`m4a` → `audio/mp4`, `wav` → `audio/wav`, `mp3` → `audio/mpeg`, `aiff`/`aif` → `audio/aiff`,
`mp4` → `video/mp4`, `mov` → `video/quicktime`; anything else `application/octet-stream`.

## Security model

- **Tailnet-only.** The server binds to `127.0.0.1` and is reached through
  `tailscale serve` (HTTPS, tailnet members only). Funnel is never used.
- **Optional login allowlist** (`GKS_ALLOWED_LOGINS`) checks the `Tailscale-User-Login`
  header that `tailscale serve` injects for tailnet users. Any **local** process can
  connect to `127.0.0.1` directly and spoof that header; this is accepted because the Mac
  is Sil's own machine. The allowlist guards against other tailnet devices/users, not
  against local code.
- **Path safety.** Every path is validated before touching disk: `..`, `.`, empty
  segments, absolute paths, NUL bytes and backslashes → `400`. Any segment starting with
  `.` (`.git/…`, `.env`, …) or named `node_modules` → `403`. After `realpath`, the target
  (or, for a create, its nearest existing ancestor) must still be inside the realpath of
  the root and not on a hidden path → otherwise `403` (blocks symlink escapes). Dangling
  symlinks are never written through.

## Run

```bash
npm install                                         # at the repo root
npm run build -w @gitkittie/gitkanban-server
GKS_ROOT="$HOME/Projects" npm start -w @gitkittie/gitkanban-server
GKS_ROOT="$HOME/Projects" npm run dev -w @gitkittie/gitkanban-server   # tsx watch
```

Scripts: `dev`, `build`, `start`, `typecheck`, `test`.

## Install as an always-on service (macOS)

```bash
apps/gitkanban-server/tools/install-launchd.sh "$HOME/Projects" [--port 4417] [--allowed-logins you@example.com]
apps/gitkanban-server/tools/install-launchd.sh "$HOME/Projects" --dry-run   # print the plist only
```

Builds the server, writes `~/Library/LaunchAgents/com.gitkittie.gitkanban-server.plist`
(`RunAtLoad`, `KeepAlive`, `GKS_*` env vars, the absolute path of the current `node`
binary), logs to `~/Library/Logs/gitkanban-server.log`, and reloads it with
`launchctl bootout` / `bootstrap`. Re-run after pulling to rebuild and restart.

Then expose it on the tailnet:

```bash
apps/gitkanban-server/tools/tailscale-serve.sh [--port 4417]
```

Runs `tailscale serve --bg --https=443 http://127.0.0.1:4417` and prints the
`https://<machine>.<tailnet>.ts.net` URL to enter in the GitKanban apps.

## Finding the server from the apps

The server announces itself with Bonjour (`_gitkanban._tcp`, through macOS's built-in
`dns-sd`), so GitKanban lists it without anyone typing an address. The announcement only
points at the server. Its TXT record carries the Tailscale HTTPS address, so the server stays
on localhost and nothing is opened on the LAN. A phone on the same network sees it once and
saves the address, then keeps using it over Tailscale. Bonjour doesn't cross Tailscale, so a
device that has never been on the same network has to type the address.
