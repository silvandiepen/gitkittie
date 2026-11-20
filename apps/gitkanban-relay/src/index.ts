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
//
// Only GitKittie clients register: each install sends its own random id and a hash that
// ties it to the client family (`clientProof` in signature.ts). Nothing to configure on a
// deployment, so it works for every client and every relay alike.
//
// The app that registers a channel creates the webhook on the provider with `hookSecret` and
// commits `channel` + `subscribeKey` into the repo, so whoever can read the repo can
// subscribe and nobody else can.

import { DurableObject } from "cloudflare:workers";
import { Hono } from "hono";
import type { ContentfulStatusCode } from "hono/utils/http-status";
import { changeEvent } from "./push.js";
import { randomHex, sameSecret, verifiedClient, verify } from "./signature.js";

export interface Env {
  CHANNEL: DurableObjectNamespace<Channel>;
}

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
