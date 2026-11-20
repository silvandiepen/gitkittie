// End-to-end check of a running relay (local `wrangler dev`, or a deployed one):
//   RELAY_URL=http://127.0.0.1:8787 node tools/e2e.mjs
// Registers a channel, subscribes, delivers pushes the way GitHub and GitLab would, and
// checks what arrives, plus the refusals. Removes the channel again at the end.
// It registers the way a GitKittie client does: a random id plus the family hash.
import { createHmac, randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";

const base = (process.env.RELAY_URL ?? "http://127.0.0.1:8787").replace(/\/$/, "");
let failed = 0;
const check = (name, ok, detail = "") => {
  if (!ok) failed += 1;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || !detail ? "" : `: ${detail}`}`);
};
const sign = (secret, body) => `sha256=${createHmac("sha256", secret).update(body).digest("hex")}`;

// The client family value, read from the relay's own source so the two cannot drift.
const family = /CLIENT_FAMILY = "([^"]+)"/.exec(readFileSync(new URL("../src/signature.ts", import.meta.url), "utf8"))[1];
const now = () => Math.floor(Date.now() / 1000);
const register = (repo, { signWith = family, time = now(), signed = true } = {}) => {
  const body = JSON.stringify({ repo });
  const id = randomBytes(16).toString("hex");
  const mac = createHmac("sha256", signWith).update(`${id}.${time}.${body}`).digest("hex");
  return fetch(`${base}/channels`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(signed ? { "x-gitkanban-client": `id=${id},t=${time},v1=${mac}` } : {}) },
    body,
  });
};

const anonymous = await register("octo/board", { signed: false });
const wrongKey = await register("octo/board", { signWith: "not-the-family" });
const stale = await register("octo/board", { time: now() - 3600 });
check(
  "registration without a client proof, with a hash from outside the family, or with an old one is refused",
  anonymous.status === 401 && wrongKey.status === 401 && stale.status === 401,
  `${anonymous.status} ${wrongKey.status} ${stale.status}`,
);

const created = await register("octo/board");
check("a registration from a client with a fresh random id is accepted", created.status === 201, `status ${created.status}`);
const channel = await created.json();
check("registration returns ids, secrets and URLs", Boolean(channel.channel && channel.hookSecret && channel.subscribeKey && channel.hookURL && channel.socketURL));

const badRepo = await register("nope");
check("a malformed repo name is refused", badRepo.status === 400, `status ${badRepo.status}`);
const nested = await register("group/subgroup/board");
check("a GitLab subgroup path is a valid repo", nested.status === 201, `status ${nested.status}`);
const nestedChannel = await nested.json();
await fetch(`${base}/channels/${nestedChannel.channel}?key=${nestedChannel.subscribeKey}`, { method: "DELETE" });

function subscribe(key) {
  return new Promise((resolve) => {
    const socket = new WebSocket(`${channel.socketURL}?key=${key}`);
    const messages = [];
    const waiters = [];
    socket.addEventListener("message", (event) => {
      messages.push(String(event.data));
      waiters.splice(0).forEach((wake) => wake());
    });
    socket.addEventListener("open", () => resolve({ socket, messages, opened: true, next: () => new Promise((wake) => waiters.push(wake)) }));
    socket.addEventListener("error", () => resolve({ socket, messages, opened: false }));
  });
}
const within = (promise, ms) => Promise.race([promise, new Promise((resolve) => setTimeout(resolve, ms))]);

const intruder = await subscribe("0".repeat(64));
check("a wrong subscribe key cannot connect", !intruder.opened);

const first = await subscribe(channel.subscribeKey);
const second = await subscribe(channel.subscribeKey);
check("two subscribers connect", first.opened && second.opened);
if (first.messages.length === 0) await within(first.next(), 2000);
check("a subscriber is greeted with the repo", first.messages[0] === JSON.stringify({ type: "hello", repo: "octo/board" }), first.messages[0]);

first.socket.send("ping");
await within(first.next(), 2000);
check("keep-alive ping is answered", first.messages.includes("pong"), JSON.stringify(first.messages));

const push = JSON.stringify({
  ref: "refs/heads/main",
  after: "0123abc",
  commits: [{ added: ["Tasks/Pets/1. To do/new.md"], modified: ["Tasks/Pets/README.md"], removed: [] }],
});
const deliver = (body, signature, event = "push") =>
  fetch(channel.hookURL, {
    method: "POST",
    headers: { "content-type": "application/json", "x-github-event": event, ...(signature ? { "x-hub-signature-256": signature } : {}) },
    body,
  });

const unsigned = await deliver(push, null);
const forged = await deliver(push, sign("not-the-secret", push));
check("an unsigned or forged delivery is refused", unsigned.status === 401 && forged.status === 401, `${unsigned.status} ${forged.status}`);
check("nothing was relayed for them", !first.messages.some((message) => message.includes('"push"')));

const ping = await deliver("{}", sign(channel.hookSecret, "{}"), "ping");
check("GitHub's ping is acknowledged", ping.status === 200);

const delivered = await deliver(push, sign(channel.hookSecret, push));
const receipt = await delivered.json();
check("a signed push is accepted", delivered.status === 200 && receipt.delivered === 2, JSON.stringify(receipt));
for (const subscriber of [first, second]) {
  if (!subscriber.messages.some((message) => message.includes('"push"'))) await within(subscriber.next(), 3000);
}
const expected = JSON.stringify({
  type: "push",
  ref: "refs/heads/main",
  head: "0123abc",
  paths: ["Tasks/Pets/1. To do/new.md", "Tasks/Pets/README.md"],
  complete: true,
});
check("both subscribers get the changed paths", first.messages.includes(expected) && second.messages.includes(expected), JSON.stringify(first.messages));

// GitLab: the secret arrives as a token, the event is named "Push Hook".
const gitlabPush = JSON.stringify({
  object_kind: "push",
  ref: "refs/heads/main",
  after: "9876fed",
  total_commits_count: 1,
  commits: [{ added: [], modified: ["Tasks/Pets/2. Doing/moved.md"], removed: [] }],
});
const gitlab = (body, token, event = "Push Hook") =>
  fetch(channel.hookURL, {
    method: "POST",
    headers: { "content-type": "application/json", "x-gitlab-event": event, ...(token ? { "x-gitlab-token": token } : {}) },
    body,
  });
const gitlabNoToken = await gitlab(gitlabPush, null);
const gitlabWrongToken = await gitlab(gitlabPush, "not-the-secret");
check("a GitLab delivery without the right token is refused", gitlabNoToken.status === 401 && gitlabWrongToken.status === 401, `${gitlabNoToken.status} ${gitlabWrongToken.status}`);
const gitlabOther = await gitlab("{}", channel.hookSecret, "Merge Request Hook");
check("a GitLab event that is not a push is acknowledged and dropped", gitlabOther.status === 202, `status ${gitlabOther.status}`);
const gitlabDelivered = await gitlab(gitlabPush, channel.hookSecret);
check("a GitLab push with the token is accepted", gitlabDelivered.status === 200, `status ${gitlabDelivered.status}`);
const expectedGitLab = JSON.stringify({
  type: "push",
  ref: "refs/heads/main",
  head: "9876fed",
  paths: ["Tasks/Pets/2. Doing/moved.md"],
  complete: true,
});
for (const subscriber of [first, second]) {
  if (!subscriber.messages.includes(expectedGitLab)) await within(subscriber.next(), 3000);
}
check("both subscribers get the GitLab push's paths", first.messages.includes(expectedGitLab) && second.messages.includes(expectedGitLab), JSON.stringify(first.messages));

const elsewhere = await fetch(`${base}/hook/${"f".repeat(32)}`, { method: "POST", body: push, headers: { "x-hub-signature-256": sign(channel.hookSecret, push) } });
check("an unknown channel is not found", elsewhere.status === 404, `status ${elsewhere.status}`);

const wrongDelete = await fetch(`${base}/channels/${channel.channel}?key=nope`, { method: "DELETE" });
const removed = await fetch(`${base}/channels/${channel.channel}?key=${channel.subscribeKey}`, { method: "DELETE" });
check("only the key holder can remove a channel", wrongDelete.status === 404 && removed.status === 204, `${wrongDelete.status} ${removed.status}`);
const afterRemoval = await deliver(push, sign(channel.hookSecret, push));
check("a removed channel no longer accepts deliveries", afterRemoval.status === 404, `status ${afterRemoval.status}`);

for (const subscriber of [first, second]) subscriber.socket.close();
console.log(failed === 0 ? "\nAll checks passed." : `\n${failed} check(s) failed.`);
process.exit(failed === 0 ? 0 : 1);
