# Instant review notifications

A review request that newly needs an answer reaches the reviewer's iPhone, iPad and Mac within
seconds, through Apple's push service, even while Tasks is closed. Each request says how loudly
(`notify:` in its frontmatter). Tasks' own checks keep running as the fallback.

This lives in the existing relay (`apps/gitkanban-relay`) rather than a second Worker: it already
has the webhook signature checks, the client proof, a deployment and the GitLab channel that a
GitLab board needs.

## How it works

```
 agent writes <Board>/review/<id>/review.md and pushes
        │
 GitHub ──push event (every repo the App is installed on)──► relay POST /github
        │                                                     │ 1. check X-Hub-Signature-256 (App webhook secret)
        │                                                     │ 2. keep review.md files added/changed on the default branch
        │◄── App JWT → installation token (one repo, contents:read)
        │◄── read each review.md at the commit before and after the push
        │                                                     │ 3. something newly waits (a pending item, an unanswered
        │                                                     │    question that was not waiting before)? → an alert
        │                                                     ▼
        │                                 Durable Object github:<repo id> → its devices
        │                                                     │ 4. APNs, ES256 provider token, one request per device
        ▼                                                     ▼
                                   iPhone / iPad / Mac: "Review: <title>" — <board>
                                   tap → Tasks opens that request
```

GitLab boards have no GitHub App. There Tasks adds a project webhook itself (with the signed-in
account, which already needs the `api` scope) pointing at the repo's relay channel
(`POST /hook/<channel>`, a per-project secret; this is the Live Updates channel). The relay cannot
read GitLab files, so on a push that touches a `review.md` it sends a background push; the app
wakes, loads its inbox and announces the request itself, at its level. Background pushes are
best effort (iOS may hold them back, and does not deliver them to an app the person force-quit),
so GitLab boards are slower and less certain than GitHub ones.

### Levels

| `notify:` | Push | Interruption level | Sound |
|---|---|---|---|
| `urgent` | alert | `time-sensitive` (breaks through Focus; needs the Time Sensitive entitlement) | yes |
| `normal` (default, also when absent or unknown) | alert | `active` | yes |
| `silent` | background (`content-available`), no alert | — | no; the app updates the badge and the Reviews list |

Settings ▸ Notifications ▸ **Reviews to do** turns all of it off: the device is removed from the
relay. **Urgent requests only** sends only urgent alerts (silent wake-ups still come, to keep
the badge right).

### Nothing announced twice

A push carries `apns-collapse-id` = `review-` + 32 hex of SHA-256(`<repo>|<request folder>`), and
the app posts its own notification for a request under the same identifier
(`reviewNotificationID` in `swift/GitKanbanKit/ReviewPush.swift`; the relay's `collapseID` in
`src/apns.ts`; both tests share a vector). When the app does its own check it skips a request a
push already announced (noted when the push arrives or is tapped) or whose notification is still
on screen.

### Registering a device

At launch Tasks asks iOS / macOS for a push token, then registers it for every added repo:

- **GitHub:** `POST /github/devices` with the client proof (`X-GitKanban-Client`, as for channels)
  and the person's own GitHub token in `Authorization`. The relay calls `GET /repos/<repo>` with
  that token once and needs `permissions.pull: true`, so nobody can subscribe to a repo they
  cannot read; the token is not stored or logged. Then it asks GitHub, as the App, whether the App
  is installed on the repo (`GET /repos/<repo>/installation`). Not installed → `409` with the page
  to install it (`github.com/apps/gitkittie-tasks/installations/new/permissions?suggested_target_id=<owner>&repository_ids[]=<repo>`),
  which Tasks shows as **Turn On** in Settings ▸ Notifications and opens in a web sign-in sheet.
  After installing, GitHub goes to the App's setup URL
  (`gitkittie.hakobs.com/tasks/github-installed`, `apps/website/public/tasks/github-installed.html`),
  which passes on to `gitkittie-tasks://github-installed`; the sheet closes and Tasks registers again.
- **GitLab:** `POST /channels/<channel>/devices` with the channel's `subscribeKey`, read from
  `.gitkanban/relay.json` in the repo (holding it proves the device can read the repo). A repo
  without a channel shows **Turn On**, which creates the channel and the webhook.
- **Removing:** `DELETE /github/devices` (repo id + device token; only the device and Apple know the
  token) or `DELETE /channels/<channel>/devices` (subscribe key + token). Apple's `410` /
  `BadDeviceToken` removes a device, and so does not re-registering for 45 days.

The app never calls GitHub or GitLab for this itself (the GitPont rule in the root `AGENTS.md`):
the relay builds the install page's address.

## What the relay sees and stores

For the App Store privacy label and the site's privacy page. Proposed text for the site:

> **Instant notifications.** If you turn on instant review notifications, your device's push
> token, its platform (iOS or macOS), the app version and the notification levels you chose are
> kept on our relay together with the repositories you get notifications for, so the relay knows
> where to send them. When a review request is pushed to such a repository, the relay reads that
> request's file once, takes its title, board name and notification level, sends the notification
> through Apple's push service and forgets the file. It stores nothing from your repositories and
> keeps no history. On GitHub the relay reads files as the GitKittie Tasks app, only in
> repositories you installed it on and only with read access; when you turn notifications on, your
> GitHub token is used once to check that you can read the repository and is not kept. Turning the
> notifications off removes your device from the relay.

App Store privacy label: **Identifiers → Device ID** (the push token), *not linked to identity*,
*not used for tracking*, purpose *App Functionality*. Nothing else is collected: the GitHub token is
used transiently and not stored, and repository content is processed transiently. Check this
against the current label in App Store Connect before submitting.

Per device the relay stores `{token, platform, environment, levels, appVersion, verifiedAt}` under
the repo (Durable Object `github:<repo id>` with the repo's name, or the channel's object). The
review file, its notes, items and comments are never stored, logged or forwarded; only
`title`, the board name, the request's folder and id, and the level go into the push.

## The GitHub App

Created on 2026-11-28 through GitHub's manifest flow, owned by `silvandiepen`.

| Setting | Value | Why |
|---|---|---|
| Name / slug | GitKittie Tasks / `gitkittie-tasks` | What people see on the install page |
| App id | `5963429` (in `wrangler.jsonc`) | `iss` of the App JWT |
| Client id | `Iv23lisxOTF8hcYy9T8j` | Not used yet; for device-flow sign-in later |
| Public | yes | Anyone with a Tasks board can install it on their repo |
| Permissions | Contents: **read**; Metadata: **read** | Contents to read a `review.md` at a commit; Metadata is mandatory for every App. Nothing can be written |
| Events | Push | The only event the relay acts on |
| Webhook URL | `https://gitkanban-relay.vandipyan.workers.dev/github` once live (created inactive, placeholder `https://example.invalid/github`) | One URL for every installation |
| Setup URL | `https://gitkittie.hakobs.com/tasks/github-installed`, redirect on update | Brings people back into Tasks after installing |
| Callback / redirect URL | a localhost listener, used once for the manifest code exchange | Not used afterwards |

`../github-app-manifest.json` is the manifest without secrets (with the webhook as it should be once
live). **To recreate the App** (a new owner, or after deleting it): serve a page that POSTs that
JSON as `manifest` to `https://github.com/settings/apps/new?state=<random>`, with `redirect_url`
pointing at a local listener; GitHub redirects there with a `code`; exchange it once with
`POST https://api.github.com/app-manifests/<code>/conversions`, which returns the new App's id,
slug, client id/secret, webhook secret and private key. Put the three secrets in the Keychain under
the service names below, update `GITHUB_APP_ID` / `GITHUB_APP_SLUG` in `wrangler.jsonc`, and run
`scripts/go-live.sh`. Installed repos have to install the new App again.

This pairs with the onboarding design (GITKITTIE-114): GitHub Apps also do the device flow, so
signing in and installing the App could become one step later. Sign-in is unchanged here.

## Where every secret lives

| Secret | Kept in | Cloudflare secret | Used for |
|---|---|---|---|
| GitHub App private key (PEM) | Keychain, account `gitkittie-tasks`, service `gitkittie-tasks.github-app.private-key` | `GITHUB_APP_PRIVATE_KEY` | Signing the App JWT |
| GitHub App webhook secret | Keychain, service `gitkittie-tasks.github-app.webhook-secret` | `GITHUB_WEBHOOK_SECRET` | Checking `X-Hub-Signature-256` on `POST /github` |
| GitHub App client secret | Keychain, service `gitkittie-tasks.github-app.client-secret` | none (not used yet) | Device-flow sign-in, later |
| APNs key (`.p8`, key id `37WP9V9P6N`, team `38MGF83L2L`) | `~/Projects/Apple Distribution/Push/AuthKey_37WP9V9P6N.p8` | `APNS_PRIVATE_KEY` | Signing the APNs provider token |

Read a Keychain item only straight into the next command
(`security find-generic-password -a gitkittie-tasks -s <service> -w | npx wrangler secret put …`;
`go-live.sh` does this). Never print, log, commit or paste any of them. Not secret, in
`wrangler.jsonc`: `GITHUB_APP_ID`, `GITHUB_APP_SLUG`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`.
Confirm the APNs key id against the key's page in the developer portal (it is taken from the
file name).

### Rotating

- **App private key:** App settings → Private keys → Generate a private key (downloads a PEM).
  Replace the Keychain item's password with the PEM's text (Keychain Access; or
  `security add-generic-password -U -a gitkittie-tasks -s gitkittie-tasks.github-app.private-key -w "$(cat key.pem)"`,
  which shows the key to local process listings for a moment), then `security find-generic-password -a gitkittie-tasks -s gitkittie-tasks.github-app.private-key -w | npx wrangler secret put GITHUB_APP_PRIVATE_KEY`
  (if `security` prints hex, the script's `keychain_secret` shows how to decode it). Delete the old
  key in the App settings once the relay works with the new one, and delete the downloaded file.
- **Webhook secret:** make a new random value (`openssl rand -hex 32`), set it in App settings →
  Webhook secret, update the Keychain item and `GITHUB_WEBHOOK_SECRET`. Deliveries in between fail
  their signature check (and can be redelivered from the deliveries page).
- **Client secret:** App settings → Client secrets → Generate a new client secret; update the
  Keychain item. Nothing uses it yet.
- **APNs key:** create a new key with APNs in the developer portal (Keys), keep the `.p8` in
  `~/Projects/Apple Distribution/Push/`, `npx wrangler secret put APNS_PRIVATE_KEY < <file>`, set
  `APNS_KEY_ID` in `wrangler.jsonc` and deploy, then revoke the old key.

## Going live (Sil)

`scripts/go-live.sh` does the runnable part. Nothing here was run by an agent.

1. `npx wrangler login` (once).
2. `cd apps/gitkanban-relay && zsh scripts/go-live.sh`: typecheck and tests, the three secrets
   from the Keychain and the `.p8`, `wrangler deploy` (adds the `GitHubRepo` Durable Object,
   migration `v2`; no KV or D1 is needed), then sets the App's webhook URL to `<relay>/github`
   through `PATCH /app/hook/config`, authenticated as the App.
3. In the App's settings (github.com/settings/apps/gitkittie-tasks) tick **Active** under Webhook
   and save; GitHub has no API for that. A ping should show `200` under Advanced → Recent Deliveries.
4. Apple: the App ID `app.hakobs.gitkanban` needs **Push Notifications** and **Time Sensitive
   Notifications**. Automatic signing (Xcode, or `./fl build app:gitkanban` in `~/Projects/_appstore`
   with `-allowProvisioningUpdates`) adds both and makes a new profile on the next signed build;
   that changes the portal. The hub has no lane for capabilities. Or tick both by hand under
   Identifiers. The `.p8` key is team-wide, so no per-app key is needed.
5. Ship Tasks with this branch (entitlements and background mode are in `project.yml`).
6. In Tasks: Notifications → Instant review notifications → **Turn On** for the board repo
   (installs the App on `silvandiepen/tasks`, with the repo chosen for you).

There is no repository webhook to add by hand, and users have nothing to configure on GitHub.

## Check it works

- `curl https://gitkanban-relay.vandipyan.workers.dev/` answers `{"service":"gitkanban-relay","ok":true}`.
- Ask a review with `notify: urgent` on an installed repo; the App's Recent Deliveries shows the
  push with a `200` body like `{"ok":true,"reviews":1,"alerts":1,"sent":2}`.
- `alerts: 0`: nothing newly waits (a decision or a comment), or the file is not on the default
  branch. `sent: 0` with alerts: no device registered for that repo, or Apple refused (logs).
- `503 push notifications are not set up`: a secret is missing (`npx wrangler secret list`).
- `401` on deliveries: the webhook secret on GitHub and `GITHUB_WEBHOOK_SECRET` differ.
- Relay logs: `npx wrangler tail gitkanban-relay` (observability is on; the relay logs no file
  contents and no tokens).
- Apple's answers: `403 InvalidProviderToken` = key id, team or `.p8` wrong;
  `400 BadDeviceToken` = a development build's token sent to production or the other way round
  (the app says `sandbox` in Debug builds).

**Not verified yet:** that a Worker's `fetch` reaches APNs (Apple requires HTTP/2). A Workers fork of
`apns2` does exactly this, so it is expected to work, but the first real send settles it; if it
fails, the APNs sender needs another way out (a small HTTP/2 proxy), the rest stands.
