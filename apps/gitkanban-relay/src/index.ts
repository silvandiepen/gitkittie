// GitKanban relay.
//
// A repo's push webhook (GitHub or GitLab) comes in, is checked against the secret the hook
// was created with, and goes out to that repo's subscribers as "these paths changed". The
// relay never sees file contents or anyone's git token, and keeps nothing but each
// channel's two secrets.
//
//   POST   /channels                     register a channel        -> ids, secrets, URLs
//                                        (with a GitKittie client's proof)
//   POST   /hook/:channel                the webhook target        (GitHub signs with
//                                        hookSecret, GitLab sends it as its token)
//   GET    /channels/:channel/socket     WebSocket for subscribers (?key=subscribeKey)
//   DELETE /channels/:channel            remove a channel          (?key=subscribeKey)
//   POST   /channels/:channel/devices    a device wants review pushes for the channel's repo
//   DELETE /channels/:channel/devices    ...and no longer          (both with subscribeKey)
//
// Push notifications for review requests (see docs/Push.md):
//
//   POST   /github                       the "GitKittie Tasks" GitHub App's webhook (push
//                                        events of every repo it is installed on)
//   POST   /github/devices               a device wants review pushes for a GitHub repo
//                                        (with a client proof and the person's GitHub token,
//                                        used once to check they can read the repo)
//   DELETE /github/devices               ...and no longer (holding the device token is the proof)
//
// Only GitKittie clients register: each install sends its own random id and a hash that
// ties it to the client family (`clientProof` in signature.ts). Nothing to configure on a
// deployment, so it works for every client and every relay alike.
//
// The app that registers a channel creates the webhook on the provider with `hookSecret` and
// commits `channel` + `subscribeKey` into the repo, so whoever can read the repo can
// subscribe and nobody else can.
//
// A review request that newly needs an answer is announced on the person's devices through
// Apple's push service. On GitHub the relay reads the request's frontmatter as the GitHub
// App (contents: read, only on repos where it is installed) and sends an alert at the
// request's `notify` level. On a channel (GitLab) it cannot read files, so it wakes the app,
// which looks for itself. Nothing read from a file is stored.

import { DurableObject } from "cloudflare:workers";
import { Hono } from "hono";
import type { ContentfulStatusCode } from "hono/utils/http-status";
import { alertRequest, providerToken, send, wakeRequest, type APNsConfig, type Device, type SendOutcome } from "./apns.js";
import { isCurrent, MAX_DEVICES_PER_REPO, parseDevice, recipients } from "./devices.js";
import { installURL, readableRepo, repoInstallation, type GitHubAppConfig } from "./github.js";
import { changeEvent } from "./push.js";
import { alertsForPush, reviewPush, type ReviewAlert } from "./review-push.js";
import { randomHex, sameSecret, verifiedClient, verify } from "./signature.js";

export interface Env {
  CHANNEL: DurableObjectNamespace<Channel>;
  GITHUB_REPO: DurableObjectNamespace<GitHubRepo>;
  /** The GitHub App (vars in wrangler.jsonc; the key and webhook secret are secrets). */
  GITHUB_APP_ID?: string;
  GITHUB_APP_SLUG?: string;
  GITHUB_APP_PRIVATE_KEY?: string;
  GITHUB_WEBHOOK_SECRET?: string;
  /** Apple's push service (key id and team are vars; the .p8 key is a secret). */
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_TOPIC?: string;
  APNS_PRIVATE_KEY?: string;
}

function githubApp(env: Env): GitHubAppConfig | null {
  if (!env.GITHUB_APP_ID || !env.GITHUB_APP_SLUG || !env.GITHUB_APP_PRIVATE_KEY) return null;
  return { appID: env.GITHUB_APP_ID, slug: env.GITHUB_APP_SLUG, privateKey: env.GITHUB_APP_PRIVATE_KEY };
}

function apns(env: Env): APNsConfig | null {
  if (!env.APNS_KEY_ID || !env.APNS_TEAM_ID || !env.APNS_TOPIC || !env.APNS_PRIVATE_KEY) return null;
  return { keyID: env.APNS_KEY_ID, teamID: env.APNS_TEAM_ID, topic: env.APNS_TOPIC, privateKey: env.APNS_PRIVATE_KEY };
}

const unixNow = (): number => Math.floor(Date.now() / 1000);
const outbound = (request: Request): Promise<Response> => fetch(request);

/** The headers a provider authenticates and labels a webhook delivery with. */
interface HookHeaders {
  githubSignature: string | null;
  githubEvent: string | null;
  gitlabToken: string | null;
  gitlabEvent: string | null;
}

/** What the webhook endpoint answers the provider with (shown in the hook's delivery log). */
interface HookResult {
  status: number;
  body: { ok?: boolean; error?: string; pong?: boolean; ignored?: string; delivered?: number; paths?: number };
}

interface ChannelRecord {
  repo: string;
  hookSecret: string;
  subscribeKey: string;
  /** The install that registered the channel (its random id), to tell clients apart. */
  client: string;
  createdAt: string;
}

const CHANNEL_ID = /^[0-9a-f]{32}$/;
/** `owner/name`, or GitLab's `group/subgroup/name`. */
const REPO_NAME = /^[A-Za-z0-9_.-]{1,100}(\/[A-Za-z0-9_.-]{1,100}){1,20}$/;
/** A registration is one short JSON object. */
const MAX_REGISTRATION_BYTES = 2_000;
/** A push payload is small; anything near GitHub's 25 MB cap is not one we need. */
const MAX_HOOK_BYTES = 5_000_000;
/** A device registration is one short JSON object. */
const MAX_DEVICE_BYTES = 2_000;

const app = new Hono<{ Bindings: Env }>();

app.get("/", (context) => context.json({ service: "gitkanban-relay", ok: true }));

app.post("/channels", async (context) => {
  const text = await context.req.text();
  if (text.length > MAX_REGISTRATION_BYTES) return context.json({ error: "payload too large" }, 413);
  const client = await verifiedClient(text, context.req.header("x-gitkanban-client"), Math.floor(Date.now() / 1000));
  if (!client) return context.json({ error: "not accepted" }, 401);
  let body: { repo?: unknown } | null = null;
  try {
    body = JSON.parse(text) as { repo?: unknown } | null;
  } catch {
    // Falls through to the repo check.
  }
  const repo = typeof body?.repo === "string" ? body.repo : "";
  if (!REPO_NAME.test(repo)) return context.json({ error: "repo must be owner/name" }, 400);

  const channel = randomHex(16);
  const record: ChannelRecord = {
    repo,
    hookSecret: randomHex(32),
    subscribeKey: randomHex(32),
    client,
    createdAt: new Date().toISOString(),
  };
  await context.env.CHANNEL.get(context.env.CHANNEL.idFromName(channel)).create(record);
  const origin = new URL(context.req.url).origin;
  return context.json(
    {
      channel,
      hookSecret: record.hookSecret,
      subscribeKey: record.subscribeKey,
      hookURL: `${origin}/hook/${channel}`,
      socketURL: `${origin.replace(/^http/, "ws")}/channels/${channel}/socket`,
    },
    201,
  );
});

app.post("/hook/:channel", async (context) => {
  const channel = context.req.param("channel");
  if (!CHANNEL_ID.test(channel)) return context.json({ error: "unknown channel" }, 404);
  const length = Number(context.req.header("content-length") ?? 0);
  if (length > MAX_HOOK_BYTES) return context.json({ error: "payload too large" }, 413);
  const body = await context.req.text();
  if (body.length > MAX_HOOK_BYTES) return context.json({ error: "payload too large" }, 413);
  const result = await context.env.CHANNEL.get(context.env.CHANNEL.idFromName(channel)).hook(
    body,
    {
      githubSignature: context.req.header("x-hub-signature-256") ?? null,
      githubEvent: context.req.header("x-github-event") ?? null,
      gitlabToken: context.req.header("x-gitlab-token") ?? null,
      gitlabEvent: context.req.header("x-gitlab-event") ?? null,
    },
  );
  return context.json(result.body, result.status as ContentfulStatusCode);
});

app.get("/channels/:channel/socket", async (context) => {
  const channel = context.req.param("channel");
  if (!CHANNEL_ID.test(channel)) return context.json({ error: "unknown channel" }, 404);
  if (context.req.header("upgrade")?.toLowerCase() !== "websocket") {
    return context.json({ error: "expected a WebSocket upgrade" }, 426);
  }
  return context.env.CHANNEL.get(context.env.CHANNEL.idFromName(channel)).fetch(context.req.raw);
});

app.delete("/channels/:channel", async (context) => {
  const channel = context.req.param("channel");
  if (!CHANNEL_ID.test(channel)) return context.json({ error: "unknown channel" }, 404);
  const removed = await context.env.CHANNEL.get(context.env.CHANNEL.idFromName(channel)).remove(
    context.req.query("key") ?? "",
  );
  return removed ? context.body(null, 204) : context.json({ error: "unknown channel" }, 404);
});

/** The JSON body of a small request, or `null`. */
function json(text: string): Record<string, unknown> | null {
  try {
    const value = JSON.parse(text) as unknown;
    return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

app.post("/channels/:channel/devices", async (context) => {
  const channel = context.req.param("channel");
  if (!CHANNEL_ID.test(channel)) return context.json({ error: "unknown channel" }, 404);
  const text = await context.req.text();
  if (text.length > MAX_DEVICE_BYTES) return context.json({ error: "payload too large" }, 413);
  if (!(await verifiedClient(text, context.req.header("x-gitkanban-client"), unixNow()))) {
    return context.json({ error: "not accepted" }, 401);
  }
  const body = json(text);
  const device = parseDevice(body?.device, new Date());
  if (!device) return context.json({ error: "not a device registration" }, 400);
  const result = await context.env.CHANNEL.get(context.env.CHANNEL.idFromName(channel)).addDevice(
    typeof body?.key === "string" ? body.key : "",
    device,
  );
  return context.json(result.body, result.status as ContentfulStatusCode);
});

app.delete("/channels/:channel/devices", async (context) => {
  const channel = context.req.param("channel");
  if (!CHANNEL_ID.test(channel)) return context.json({ error: "unknown channel" }, 404);
  const text = await context.req.text();
  if (text.length > MAX_DEVICE_BYTES) return context.json({ error: "payload too large" }, 413);
  const body = json(text);
  const removed = await context.env.CHANNEL.get(context.env.CHANNEL.idFromName(channel)).removeDevice(
    typeof body?.key === "string" ? body.key : "",
    typeof body?.token === "string" ? body.token.toLowerCase() : "",
  );
  return removed ? context.body(null, 204) : context.json({ error: "unknown device" }, 404);
});

// The GitHub App's webhook: every repo the App is installed on, one URL, one secret.
app.post("/github", async (context) => {
  const secret = context.env.GITHUB_WEBHOOK_SECRET;
  const config = githubApp(context.env);
  if (!secret || !config) return context.json({ error: "push notifications are not set up on this relay" }, 503);
  const length = Number(context.req.header("content-length") ?? 0);
  if (length > MAX_HOOK_BYTES) return context.json({ error: "payload too large" }, 413);
  const body = await context.req.text();
  if (body.length > MAX_HOOK_BYTES) return context.json({ error: "payload too large" }, 413);
  if (!(await verify(secret, body, context.req.header("x-hub-signature-256")))) return context.json({ error: "not accepted" }, 401);
  const event = context.req.header("x-github-event") ?? "";
  if (event === "ping") return context.json({ ok: true, pong: true });
  if (event !== "push") return context.json({ ok: true, ignored: event }, 202);
  const push = reviewPush(json(body));
  if (!push || push.paths.length === 0) return context.json({ ok: true, reviews: 0 });
  const alerts = await alertsForPush(push, config, outbound, unixNow());
  if (alerts.length === 0) return context.json({ ok: true, reviews: push.paths.length, alerts: 0 });
  const sent = await context.env.GITHUB_REPO.get(context.env.GITHUB_REPO.idFromName(`github:${push.repoID}`)).announce(alerts);
  return context.json({ ok: true, reviews: push.paths.length, alerts: alerts.length, sent });
});

// A device asks for review pushes on a GitHub repo. It proves it is a GitKittie client
// (`X-GitKanban-Client`) and that its person can read the repo (their GitHub token, in
// `Authorization`, used for one call to GitHub and not kept). When the App is not installed
// on the repo yet, the answer says where to install it.
app.post("/github/devices", async (context) => {
  const config = githubApp(context.env);
  if (!config) return context.json({ error: "push notifications are not set up on this relay" }, 503);
  const text = await context.req.text();
  if (text.length > MAX_DEVICE_BYTES) return context.json({ error: "payload too large" }, 413);
  if (!(await verifiedClient(text, context.req.header("x-gitkanban-client"), unixNow()))) {
    return context.json({ error: "not accepted" }, 401);
  }
  const userToken = /^Bearer (\S{1,512})$/.exec(context.req.header("authorization") ?? "")?.[1];
  const body = json(text);
  const repoName = typeof body?.repo === "string" ? body.repo : "";
  const device = parseDevice(body?.device, new Date());
  if (!userToken || !REPO_NAME.test(repoName) || !device) return context.json({ error: "not a device registration" }, 400);
  const repo = await readableRepo(userToken, repoName, outbound);
  // The same answer for "no such repo" and "not yours": nothing to learn about other people's repos.
  if (!repo) return context.json({ error: "this account cannot read that repository" }, 403);
  const installation = await repoInstallation(config, repo.repo, outbound, unixNow());
  if (installation === null) {
    return context.json({ error: "not installed", installURL: installURL(config, repo), repoID: repo.repoID }, 409);
  }
  const stub = context.env.GITHUB_REPO.get(context.env.GITHUB_REPO.idFromName(`github:${repo.repoID}`));
  const added = await stub.addDevice(repo.repo, device);
  if (!added) return context.json({ error: "too many devices on this repository" }, 429);
  return context.json({ ok: true, repoID: repo.repoID, installation }, 201);
});

app.delete("/github/devices", async (context) => {
  const text = await context.req.text();
  if (text.length > MAX_DEVICE_BYTES) return context.json({ error: "payload too large" }, 413);
  const body = json(text);
  const repoID = typeof body?.repoID === "number" && Number.isSafeInteger(body.repoID) ? body.repoID : null;
  const token = typeof body?.token === "string" ? body.token.toLowerCase() : "";
  if (repoID === null || !token) return context.json({ error: "give repoID and token" }, 400);
  const removed = await context.env.GITHUB_REPO.get(context.env.GITHUB_REPO.idFromName(`github:${repoID}`)).removeDevice(token);
  return removed ? context.body(null, 204) : context.json({ error: "unknown device" }, 404);
});

export default app;

/** One channel: its secrets and the sockets subscribed to it. */
export class Channel extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Keep-alives are answered without waking the object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  private record(): Promise<ChannelRecord | undefined> {
    return this.ctx.storage.get<ChannelRecord>("channel");
  }

  async create(record: ChannelRecord): Promise<void> {
    // A channel id is random and used once; never overwrite an existing channel's secrets.
    if (!(await this.record())) await this.ctx.storage.put("channel", record);
  }

  async hook(body: string, headers: HookHeaders): Promise<HookResult> {
    const record = await this.record();
    // GitLab sends the hook's secret as a token; GitHub signs the body with it.
    const fromGitLab = headers.gitlabEvent !== null || headers.gitlabToken !== null;
    const accepted =
      record !== undefined &&
      (fromGitLab
        ? headers.gitlabToken !== null && (await sameSecret(record.hookSecret, headers.gitlabToken))
        : await verify(record.hookSecret, body, headers.githubSignature));
    if (!record || !accepted) return { status: record ? 401 : 404, body: { error: "not accepted" } };
    // Anything that is not a push is acknowledged and dropped. (GitLab stops calling a hook
    // that keeps answering with errors, so these must stay 2xx.)
    const event = fromGitLab ? (headers.gitlabEvent ?? "") : (headers.githubEvent ?? "");
    if (event === "ping") return { status: 200, body: { ok: true, pong: true } };
    if (event !== (fromGitLab ? "Push Hook" : "push")) return { status: 202, body: { ok: true, ignored: event } };
    let payload: unknown;
    try {
      payload = JSON.parse(body);
    } catch {
      return { status: 400, body: { error: "not JSON" } };
    }
    const change = changeEvent(payload);
    if (!change) return { status: 400, body: { error: "not a push payload" } };
    const message = JSON.stringify(change);
    // Review requests changed: wake the devices that asked, so the app looks for itself.
    if (change.paths.some((path) => /\/review\/[^/]+\/review\.md$/.test(path))) {
      this.ctx.waitUntil(this.wake(record.repo));
    }
    const sockets = this.ctx.getWebSockets();
    for (const socket of sockets) {
      try {
        socket.send(message);
      } catch {
        // A socket that went away is cleaned up by its close event.
      }
    }
    return { status: 200, body: { ok: true, delivered: sockets.length, paths: change.paths.length } };
  }

  async addDevice(key: string, device: Device): Promise<HookResult> {
    const record = await this.record();
    if (!record || !(await sameSecret(record.subscribeKey, key))) {
      return { status: record ? 401 : 404, body: { error: "not accepted" } };
    }
    const devices = await this.ctx.storage.list<Device>({ prefix: "device:" });
    if (!devices.has(`device:${device.token}`) && devices.size >= MAX_DEVICES_PER_REPO) {
      return { status: 429, body: { error: "too many devices on this channel" } };
    }
    await this.ctx.storage.put(`device:${device.token}`, device);
    return { status: 201, body: { ok: true } };
  }

  async removeDevice(key: string, token: string): Promise<boolean> {
    const record = await this.record();
    if (!record || !(await sameSecret(record.subscribeKey, key))) return false;
    return this.ctx.storage.delete(`device:${token}`);
  }

  private async wake(repo: string): Promise<void> {
    const config = apns(this.env);
    if (!config) return;
    const now = new Date();
    const devices = [...(await this.ctx.storage.list<Device>({ prefix: "device:" })).values()];
    if (devices.length === 0) return;
    const token = await providerToken(config, unixNow());
    for (const device of devices) {
      if (!isCurrent(device, now)) {
        await this.ctx.storage.delete(`device:${device.token}`);
        continue;
      }
      if ((await send(wakeRequest(repo, device, token, config.topic), outbound)) === "gone") {
        await this.ctx.storage.delete(`device:${device.token}`);
      }
    }
  }

  async remove(key: string): Promise<boolean> {
    const record = await this.record();
    if (!record || !(await sameSecret(record.subscribeKey, key))) return false;
    for (const socket of this.ctx.getWebSockets()) socket.close(1000, "channel removed");
    await this.ctx.storage.deleteAll();
    return true;
  }

  /** A subscriber connecting. */
  override async fetch(request: Request): Promise<Response> {
    const record = await this.record();
    const key = new URL(request.url).searchParams.get("key") ?? "";
    if (!record || !(await sameSecret(record.subscribeKey, key))) {
      return Response.json({ error: "not accepted" }, { status: record ? 401 : 404 });
    }
    const pair = new WebSocketPair();
    // Hibernatable: the object sleeps between pushes while the sockets stay open.
    this.ctx.acceptWebSocket(pair[1]);
    pair[1].send(JSON.stringify({ type: "hello", repo: record.repo }));
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  override webSocketClose(socket: WebSocket, code: number): void {
    try {
      socket.close(code === 1005 || code === 1006 ? 1000 : code);
    } catch {
      // Already closed.
    }
  }
}

/** One GitHub repository's devices (keyed `github:<repo id>`), and sending its review alerts. */
export class GitHubRepo extends DurableObject<Env> {
  async addDevice(repo: string, device: Device): Promise<boolean> {
    const devices = await this.ctx.storage.list<Device>({ prefix: "device:" });
    if (!devices.has(`device:${device.token}`) && devices.size >= MAX_DEVICES_PER_REPO) return false;
    await this.ctx.storage.put("repo", repo);
    await this.ctx.storage.put(`device:${device.token}`, device);
    return true;
  }

  async removeDevice(token: string): Promise<boolean> {
    return this.ctx.storage.delete(`device:${token}`);
  }

  /** Send each alert to the devices that want its level. Returns how many pushes Apple accepted. */
  async announce(alerts: ReviewAlert[]): Promise<number> {
    const config = apns(this.env);
    if (!config) return 0;
    const now = new Date();
    const devices = [...(await this.ctx.storage.list<Device>({ prefix: "device:" })).values()];
    const gone = new Set<string>();
    let sent = 0;
    const token = await providerToken(config, unixNow());
    for (const alert of alerts) {
      for (const device of recipients(devices, alert, now)) {
        if (gone.has(device.token)) continue;
        const outcome: SendOutcome = await send(await alertRequest(alert, device, token, config.topic), outbound);
        if (outcome === "sent") sent += 1;
        if (outcome === "gone") gone.add(device.token);
      }
    }
    // Forget devices Apple no longer knows, and ones that stopped re-registering.
    for (const device of devices) {
      if (gone.has(device.token) || !isCurrent(device, now)) await this.ctx.storage.delete(`device:${device.token}`);
    }
    return sent;
  }
}
