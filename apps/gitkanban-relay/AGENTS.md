# GitKanban relay — Agent Instructions

Read the root [`../../AGENTS.md`](../../AGENTS.md) first.

## What it is

A Cloudflare Worker that turns a repo's **push webhook** (GitHub or GitLab) into live "these paths
changed" events for the GitKanban apps, so a board updates when someone pushes without the apps
polling.

- `POST /channels` registers a channel for `owner/name` (or GitLab's `group/sub/name`) and returns
  its id, a `hookSecret` and a `subscribeKey`. It must carry a client proof,
  `X-GitKanban-Client: id=<the install's random 32-hex id>,t=<unix seconds>,v1=<hex HMAC-SHA256
  of "<id>.<t>.<body>" keyed with CLIENT_FAMILY>`, no older or newer than five minutes.
- `POST /hook/:channel` is the webhook target. GitHub: a valid `X-Hub-Signature-256` for
  `hookSecret`, event `push`. GitLab: `X-Gitlab-Token` equal to `hookSecret`, event `Push Hook`.
  Other events are acknowledged with 2xx and dropped (GitLab disables a hook that keeps failing).
- `GET /channels/:channel/socket?key=…` is the subscribers' WebSocket.
- `DELETE /channels/:channel?key=…` removes a channel.

One Durable Object per channel (`Channel` in `src/index.ts`) holds the two secrets and the open
sockets, using WebSocket hibernation so it sleeps between pushes.

## Rules

- **The relay never handles file contents or git tokens.** It relays paths only (`src/push.ts`). Do
  not add an endpoint that takes a provider token; the app proves repo access by being able to read
  `.gitkanban/relay.json` from the repo, which holds the channel and subscribe key.
- Nothing is relayed without a valid signature (GitHub) or token (GitLab).
- Nothing is registered without a client proof. `CLIENT_FAMILY` (`src/signature.ts`) must equal
  `RelayClientProof.family` in `swift/GitKittieKit`; change both together, and note that changing
  it locks out every app already installed. It is deliberately in source and not a secret, so
  never treat a valid proof as more than "this is probably one of our clients".
- Keep it stateless beyond the channel record: no logs of paths, no history, no analytics.

## Working on it

```sh
npm run typecheck -w @gitkittie/gitkanban-relay
npm test -w @gitkittie/gitkanban-relay                 # signature + payload logic
npm run dev -w @gitkittie/gitkanban-relay              # wrangler dev on :8787
RELAY_URL=http://127.0.0.1:8787 npm run e2e -w @gitkittie/gitkanban-relay   # full flow, signed fake push
RELAY_URL=http://127.0.0.1:8787 swift test --filter RelayTests              # in swift/GitKanbanKit: the app's side
```

Deploying (`npm run deploy`) is Sil's call; never deploy from an agent session unasked.

## The app side

`swift/GitKanbanKit`: `Relay.swift` (config file, WebSocket subscriber with reconnect) and
`AppModel+Relay.swift` (register the channel, commit the config) and `ProviderWebhook.swift`
(create and remove the webhook on GitHub or GitLab). The
subscriber plugs into the existing live-refresh path (`ChangeObservingSource` → `startWatching`).

`swift/GitKittieKit/RelayClientProof.swift` makes the install id and the proof; it lives in the
shared kit so any family app (GitFolder included) can register the same way.

## Not built yet

- Waking a phone whose app is closed (needs APNs on top of the relay).
- A cap or block per client id (the id is stored with each channel, nothing acts on it yet).
- GitLab does not flag a forced push in its payload, so one is relayed as an ordinary push and
  files that only the dropped commits touched are not listed.
