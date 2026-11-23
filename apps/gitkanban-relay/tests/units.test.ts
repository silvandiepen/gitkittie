import { describe, expect, it } from "vitest";
import { changeEvent, MAX_PATHS } from "../src/push.js";
import {
  CLIENT_FAMILY,
  clientProof,
  randomHex,
  REGISTRATION_WINDOW_SECONDS,
  sameSecret,
  sign,
  verifiedClient,
  verify,
} from "../src/signature.js";

describe("signature", () => {
  it("accepts GitHub's documented example", async () => {
    // From GitHub's "Validating webhook deliveries" docs.
    const header = "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17";
    expect(await verify("It's a Secret to Everybody", "Hello, World!", header)).toBe(true);
    expect(await sign("It's a Secret to Everybody", "Hello, World!")).toBe(header);
  });

  it("rejects a changed body, a wrong secret and malformed headers", async () => {
    const header = await sign("secret", "{}");
    expect(await verify("secret", "{ }", header)).toBe(false);
    expect(await verify("other", "{}", header)).toBe(false);
    expect(await verify("secret", "{}", null)).toBe(false);
    expect(await verify("secret", "{}", "sha1=abc")).toBe(false);
    expect(await verify("secret", "{}", "sha256=zz")).toBe(false);
    expect(await verify("secret", "{}", "sha256=")).toBe(false);
  });

  it("makes distinct secrets and compares them", async () => {
    const a = randomHex(32);
    expect(a).toMatch(/^[0-9a-f]{64}$/);
    expect(randomHex(32)).not.toBe(a);
    expect(await sameSecret(a, a)).toBe(true);
    expect(await sameSecret(a, `${a}0`)).toBe(false);
    expect(await sameSecret(a, "")).toBe(false);
  });
});

describe("client proof", () => {
  const body = JSON.stringify({ repo: "octo/board" });
  const now = 1_800_000_000;
  const id = "0123456789abcdef0123456789abcdef";

  it("accepts any install's random id with the family's hash", async () => {
    const header = await clientProof(id, body, now);
    expect(header).toMatch(/^id=0123456789abcdef0123456789abcdef,t=1800000000,v1=[0-9a-f]{64}$/);
    expect(await verifiedClient(body, header, now)).toBe(id);
    expect(await verifiedClient(body, header, now + REGISTRATION_WINDOW_SECONDS)).toBe(id);
    const other = randomHex(16);
    expect(await verifiedClient(body, await clientProof(other, body, now), now)).toBe(other);
  });

  it("rejects a hash from outside the family, another body or id, a stale or missing proof", async () => {
    const header = await clientProof(id, body, now);
    const foreign = (await sign("not-the-family", `${id}.${now}.${body}`)).slice("sha256=".length);
    expect(await verifiedClient(body, `id=${id},t=${now},v1=${foreign}`, now)).toBeNull();
    expect(await verifiedClient(JSON.stringify({ repo: "octo/other" }), header, now)).toBeNull();
    expect(await verifiedClient(body, header.replace(id, "f".repeat(32)), now)).toBeNull();
    expect(await verifiedClient(body, header.replace("t=1800000000", "t=1800000001"), now)).toBeNull();
    expect(await verifiedClient(body, header, now + REGISTRATION_WINDOW_SECONDS + 1)).toBeNull();
    expect(await verifiedClient(body, header, now - REGISTRATION_WINDOW_SECONDS - 1)).toBeNull();
    expect(await verifiedClient(body, null, now)).toBeNull();
    expect(await verifiedClient(body, `id=short,t=${now},v1=${"a".repeat(64)}`, now)).toBeNull();
    expect(CLIENT_FAMILY.startsWith("gitkittie-client-v1:")).toBe(true);
  });
});

describe("changeEvent", () => {
  const push = (extra: object = {}) => ({
    ref: "refs/heads/main",
    after: "abc123",
    commits: [
      { added: ["Tasks/Pets/1. To do/new.md"], modified: ["Tasks/Pets/README.md"], removed: [] },
      { added: [], modified: ["Tasks/Pets/README.md"], removed: ["Tasks/Pets/5. Done/old.md"] },
    ],
    ...extra,
  });

  it("collects each changed path once", () => {
    expect(changeEvent(push())).toEqual({
      type: "push",
      ref: "refs/heads/main",
      head: "abc123",
      paths: ["Tasks/Pets/1. To do/new.md", "Tasks/Pets/README.md", "Tasks/Pets/5. Done/old.md"],
      complete: true,
    });
  });

  it("marks a push it cannot list fully as incomplete", () => {
    expect(changeEvent(push({ forced: true }))?.complete).toBe(false);
    const many = Array.from({ length: 20 }, (_, index) => ({ modified: [`file-${index}.md`] }));
    expect(changeEvent(push({ commits: many }))?.complete).toBe(false);
    const wide = [{ added: Array.from({ length: MAX_PATHS + 5 }, (_, index) => `f${index}.md`) }];
    const event = changeEvent(push({ commits: wide }));
    expect(event?.complete).toBe(false);
    expect(event?.paths).toHaveLength(MAX_PATHS);
  });

  it("reads a GitLab push the same way", () => {
    const gitlab = {
      object_kind: "push",
      ref: "refs/heads/main",
      after: "def456",
      total_commits_count: 1,
      commits: [{ added: ["Tasks/Pets/1. To do/new.md"], modified: [], removed: ["Tasks/Pets/5. Done/old.md"] }],
    };
    expect(changeEvent(gitlab)).toEqual({
      type: "push",
      ref: "refs/heads/main",
      head: "def456",
      paths: ["Tasks/Pets/1. To do/new.md", "Tasks/Pets/5. Done/old.md"],
      complete: true,
    });
    // GitLab lists 20 commits at most and says how many there really were.
    expect(changeEvent({ ...gitlab, total_commits_count: 34 })?.complete).toBe(false);
    // A deleted branch.
    expect(changeEvent({ ...gitlab, after: "0".repeat(40), commits: [] })?.complete).toBe(false);
  });

  it("ignores what is not a push", () => {
    expect(changeEvent(null)).toBeNull();
    expect(changeEvent({ zen: "Keep it logically awesome." })).toBeNull();
    expect(changeEvent({ ref: "refs/heads/main" })).toBeNull();
    expect(changeEvent(push({ commits: [{ added: [1, null, "ok.md"] }] }))?.paths).toEqual(["ok.md"]);
  });
});
