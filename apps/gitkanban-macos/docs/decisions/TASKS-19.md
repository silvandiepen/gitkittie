---
id: TASKS-19
section: "§ 19"
title: "Instant review notifications: GitHub App + APNs through the relay, `notify:` per request (GITKITTIE-128)"
date: 2026-11-28
status: proposed
---

# § 19. Instant review notifications: GitHub App + APNs through the relay, `notify:` per request (GITKITTIE-128)

**Context.** Tasks only noticed a new review request when it looked (open, a timer, an iOS background
refresh), so a request could wait hours. Sil decided on real push through a small relay that sees
only what it needs and stores no board content, a per-request loudness (`notify: urgent | normal |
silent`, normal when absent), and, the same day, that nobody configures anything on GitHub: no
per-repo webhook.

**Decision.**

- **One relay, not two.** The push sender is part of `apps/gitkanban-relay` (it already had the
  signature checks, the client proof, a deployment and the GitLab channel). Endpoints:
  `POST /github` (the App's webhook), `POST|DELETE /github/devices`,
  `POST|DELETE /channels/:channel/devices`. Devices live in Durable Objects (`GitHubRepo` per GitHub
  repo id, the existing `Channel` per channel), not KV or D1: strongly consistent per repo, no extra
  binding. Full picture, secrets and the go-live steps: `apps/gitkanban-relay/docs/Push.md`.
- **GitHub: a GitHub App ("GitKittie Tasks", Contents read + Metadata read, Push events).** One
  app-level webhook for every installed repo, an installation token limited to one repo and to
  reading contents, no personal token on the server. Chosen over a fine-grained PAT, which works for
  one person's repos, expires, and needs a repo webhook per board. Installing is one tap in Tasks;
  the relay builds the install page's address with the repo chosen, so the app holds no GitHub URL.
- **Who may subscribe.** A device registering for a GitHub repo sends the person's own token once;
  the relay checks `permissions.pull` on `GET /repos/<repo>` and keeps nothing of it. A stranger
  cannot subscribe to a repo they cannot read. On a channel the subscribe key is the proof, as before.
- **Newly waiting, without memory.** The relay reads a touched `review.md` at the commit before and
  after the push and announces it only when an item without a decision or a question without an
  answer appears that was not waiting before. Decisions, comments and edits stay quiet. Only the
  default branch counts; more than 10 requests in one push is treated as a bulk change and capped.
- **Levels.** `urgent` → `time-sensitive` (Time Sensitive Notifications entitlement), `normal` →
  `active`, `silent` → a background push, no alert: the app reloads the inbox and badge. The same
  mapping applies to what the app announces itself. "Urgent requests only" is a per-device setting
  sent to the relay. The Reviews switch still turns everything off and removes the device.
- **GitLab:** no App exists there, and the relay must not hold a GitLab token. Tasks creates the
  project webhook itself (the existing live-updates channel, per-project secret) and the relay
  sends a background wake-up when a review changes; the app announces it. Best effort: iOS may
  delay background pushes and does not deliver them to a force-quit app.
- **Nothing twice.** Push and app share one notification id per request
  (`review-` + SHA-256(repo|folder), tested on both sides with the same vector); the app's own check
  skips what a push announced or what is still on screen. The app's checks stay as the fallback.
- **Tap opens the request.** The payload carries repo and folder; iOS pushes it onto the Reviews
  sheet's navigation path, the Mac selects it in the Reviews screen (`reviewsFocusRequest`).
- **Divergence from the GitPont rule (root AGENTS.md).** The relay calls GitHub's REST API directly
  (App JWT, installation tokens, contents, the permission check). GitPont is a Swift library and the
  relay a TypeScript Worker, and a GitHub App webhook is GitHub-only by nature. The apps still make no
  host calls for this.
- **Callback.** The App's setup URL is the website's `/tasks/github-installed`, a static page that
  passes on to `gitkittie-tasks://github-installed`, which closes the web sign-in sheet.

**Unverified.** No real push has been sent: the Worker is not deployed, the App's webhook is
inactive, and Apple's portal has no Push capability on the App ID yet. That a Worker's `fetch`
speaks HTTP/2 to APNs is expected (a Workers APNs client does it) but untested. The website page
closing `ASWebAuthenticationSession` by a script redirect is untested. Background delivery on
macOS and iOS was not exercised.

**Status.** Proposed (PR open).
