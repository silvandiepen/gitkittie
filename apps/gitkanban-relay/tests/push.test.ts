// Review push notifications: signing (real keys, generated here), the push decision, the
// GitHub and APNs requests. Only the network is stood in for: `fetch` answers like GitHub
// and Apple would, and checks what it is sent.

import { beforeEach, describe, expect, it } from "vitest";
import { alertRequest, collapseID, providerToken, resetProviderToken, send, wakeRequest, type Device, type Fetch } from "../src/apns.js";
import { isCurrent, loginKey, parseDevice, recipients } from "../src/devices.js";
import { appJWT, installURL, readableRepo, repoInstallation, resetInstallationTokens, userLogin } from "../src/github.js";
import { apnsToken, base64url, githubAppToken, importES256, importRS256, pemBody, pkcs1ToPkcs8 } from "../src/jwt.js";
import { alertsForPush, boardFolder, boardUsers, reviewAlert, reviewPush, type ReviewAlert } from "../src/review-push.js";

// --- keys -------------------------------------------------------------------------------

function pem(label: string, der: ArrayBuffer | Uint8Array): string {
  const bytes = der instanceof Uint8Array ? der : new Uint8Array(der);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  const lines = btoa(binary).match(/.{1,64}/g)!.join("\n");
  return `-----BEGIN ${label}-----\n${lines}\n-----END ${label}-----\n`;
}

function fromBase64url(text: string): Uint8Array {
  const binary = atob(text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4));
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}

function decode(part: string): Record<string, unknown> {
  return JSON.parse(new TextDecoder().decode(fromBase64url(part))) as Record<string, unknown>;
}

async function verifyJWT(jwt: string, key: CryptoKey, algorithm: Parameters<SubtleCrypto["verify"]>[0]): Promise<boolean> {
  const [header, claims, signature] = jwt.split(".");
  return crypto.subtle.verify(algorithm, key, fromBase64url(signature!), new TextEncoder().encode(`${header}.${claims}`));
}

/** The PKCS#1 key inside a PKCS#8 one (its last OCTET STRING), as GitHub would hand it out. */
function pkcs1Inside(pkcs8: Uint8Array): Uint8Array {
  let at = 0;
  const length = (): number => {
    const first = pkcs8[at++]!;
    if (first < 0x80) return first;
    let value = 0;
    for (let count = first & 0x7f; count > 0; count -= 1) value = (value << 8) | pkcs8[at++]!;
    return value;
  };
  at += 1; // SEQUENCE
  length();
  // (`at += length()` would add to the value `at` had before length() moved it.)
  at += 1; // INTEGER version
  const version = length();
  at += version;
  at += 1; // SEQUENCE algorithm
  const algorithm = length();
  at += algorithm;
  at += 1; // OCTET STRING
  const size = length();
  return pkcs8.slice(at, at + size);
}

const ec = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
const ecPEM = pem("PRIVATE KEY", (await crypto.subtle.exportKey("pkcs8", ec.privateKey)) as ArrayBuffer);
const rsa = (await crypto.subtle.generateKey(
  { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
  true,
  ["sign", "verify"],
)) as CryptoKeyPair;
const rsaPKCS8 = new Uint8Array((await crypto.subtle.exportKey("pkcs8", rsa.privateKey)) as ArrayBuffer);
const rsaPKCS1PEM = pem("RSA PRIVATE KEY", pkcs1Inside(rsaPKCS8));

describe("JWT signing", () => {
  it("signs an APNs provider token with the .p8 key (ES256)", async () => {
    const jwt = await apnsToken(await importES256(ecPEM), "ABC123DEFG", "38MGF83L2L", 1_800_000_000);
    const [header, claims] = jwt.split(".");
    expect(decode(header!)).toEqual({ alg: "ES256", kid: "ABC123DEFG" });
    expect(decode(claims!)).toEqual({ iss: "38MGF83L2L", iat: 1_800_000_000 });
    expect(fromBase64url(jwt.split(".")[2]!)).toHaveLength(64); // r||s, as JWS wants
    expect(await verifyJWT(jwt, ec.publicKey, { name: "ECDSA", hash: "SHA-256" })).toBe(true);
    const tampered = jwt.replace(/\.[^.]+\./, `.${base64url(JSON.stringify({ iss: "OTHER", iat: 1 }))}.`);
    expect(await verifyJWT(tampered, ec.publicKey, { name: "ECDSA", hash: "SHA-256" })).toBe(false);
  });

  it("wraps GitHub's PKCS#1 key into the PKCS#8 WebCrypto imports, byte for byte", () => {
    expect(pkcs1ToPkcs8(pemBody(rsaPKCS1PEM).der)).toEqual(rsaPKCS8);
  });

  it("signs a GitHub App token (RS256) from a PKCS#1 or a PKCS#8 key", async () => {
    for (const key of [rsaPKCS1PEM, pem("PRIVATE KEY", rsaPKCS8)]) {
      const jwt = await githubAppToken(await importRS256(key), "5963429", 1_800_000_000);
      const [header, claims] = jwt.split(".");
      expect(decode(header!)).toEqual({ alg: "RS256", typ: "JWT" });
      expect(decode(claims!)).toEqual({ iss: "5963429", iat: 1_800_000_000 - 60, exp: 1_800_000_000 + 540 });
      expect(await verifyJWT(jwt, rsa.publicKey, { name: "RSASSA-PKCS1-v1_5" })).toBe(true);
    }
  });

  it("reads a key pasted with literal \\n line breaks", async () => {
    await expect(importES256(ecPEM.replace(/\n/g, "\\n"))).resolves.toBeDefined();
  });

  it("reuses the APNs provider token for 50 minutes", async () => {
    resetProviderToken();
    const config = { keyID: "ABC123DEFG", teamID: "38MGF83L2L", privateKey: ecPEM, topic: "app.hakobs.gitkanban" };
    const first = await providerToken(config, 1_800_000_000);
    expect(await providerToken(config, 1_800_000_000 + 49 * 60)).toBe(first);
    expect(await providerToken(config, 1_800_000_000 + 51 * 60)).not.toBe(first);
  });
});

// --- the push decision ------------------------------------------------------------------

const PENDING = `---
config: review
id: MORROW-182-pet-models
title: Pet models, round 1
notify: urgent
items:
  - id: dog-v1
    file: dog-v1.png
    status: pending
---
Notes stay here.
`;
const DECIDED = PENDING.replace("status: pending", "status: approved\n    decided_by: sil\n    decided_at: 2026-11-08T15:00:00Z");
const REDO = DECIDED.replace("---\nNotes", "  - id: dog-v2\n    file: dog-v2.png\n    revises: dog-v1\n    status: pending\n---\nNotes");
const PATH = "Morrow/review/MORROW-182-pet-models/review.md";

describe("reviewAlert", async () => {
  it("announces a new request that waits for an answer, at its level", async () => {
    expect(await reviewAlert("octo/tasks", PATH, null, PENDING)).toEqual({
      repo: "octo/tasks",
      path: PATH,
      folder: "Morrow/review/MORROW-182-pet-models",
      id: "MORROW-182-pet-models",
      board: "Morrow",
      title: "Pet models, round 1",
      level: "urgent",
      audience: { mapped: [], logins: [], others: true },
    });
  });

  it("announces a redo, not a decision or a comment", async () => {
    expect((await reviewAlert("octo/tasks", PATH, DECIDED, REDO))?.title).toBe("Pet models, round 1");
    expect(await reviewAlert("octo/tasks", PATH, PENDING, DECIDED)).toBeNull();
    expect(await reviewAlert("octo/tasks", PATH, PENDING, PENDING.replace("Notes", "More notes"))).toBeNull();
  });

  it("is normal without notify, and takes the board from a nested folder", async () => {
    const alert = await reviewAlert("octo/tasks", "Clients/Acme/review/x/review.md", null, PENDING.replace("notify: urgent\n", ""));
    expect(alert).toMatchObject({ board: "Acme", level: "normal", folder: "Clients/Acme/review/x" });
  });

  it("announces a new question, not an answered one", async () => {
    const asked = "---\ntitle: Pick\nnotify: silent\nquestions:\n  - id: q\n    question: Which?\n    options: [a, b]\n---\n";
    const answered = asked.replace("options: [a, b]", "options: [a, b]\n    answer: [a]\n    answered_at: 2026-11-08T15:00:00Z");
    expect((await reviewAlert("octo/tasks", PATH, null, asked))?.level).toBe("silent");
    expect(await reviewAlert("octo/tasks", PATH, asked, answered)).toBeNull();
  });

  it("announces a new browser check, not a decided one", async () => {
    const check = "---\ntitle: Page\nchecks:\n  - id: page\n    url: https://example.com\n    checklist: [Loads]\n    status: pending\n---\n";
    const decided = check.replace("status: pending", "status: approved");
    expect((await reviewAlert("octo/tasks", PATH, null, check))?.title).toBe("Page");
    expect(await reviewAlert("octo/tasks", PATH, check, decided)).toBeNull();
    expect((await reviewAlert("octo/tasks", PATH, DECIDED, DECIDED.replace("---\nNotes", "checks:\n  - id: page\n    url: https://example.com\n---\nNotes")))?.id).toBe("MORROW-182-pet-models");
  });
});

function pushPayload(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    ref: "refs/heads/main",
    before: "a".repeat(40),
    after: "b".repeat(40),
    repository: { full_name: "octo/tasks", id: 42, default_branch: "main" },
    installation: { id: 7 },
    commits: [{ added: [PATH, "Morrow/review/MORROW-182-pet-models/dog-v1.png"], modified: ["Morrow/1. To do/X.md"], removed: [] }],
    ...overrides,
  };
}

describe("reviewPush", () => {
  it("keeps review files of a push to the default branch", () => {
    expect(reviewPush(pushPayload())).toEqual({
      repo: "octo/tasks",
      repoID: 42,
      installationID: 7,
      before: "a".repeat(40),
      after: "b".repeat(40),
      paths: [PATH],
    });
  });

  it("ignores other branches, deleted branches, and files removed again", () => {
    expect(reviewPush(pushPayload({ ref: "refs/heads/feature" }))).toBeNull();
    expect(reviewPush(pushPayload({ deleted: true, after: "0".repeat(40) }))).toBeNull();
    const removed = pushPayload({ commits: [{ added: [PATH] }, { removed: [PATH] }] });
    expect(reviewPush(removed)?.paths).toEqual([]);
    expect(reviewPush(pushPayload({ before: "0".repeat(40) }))?.before).toBeNull();
  });

  it("caps a bulk change", () => {
    const many = Array.from({ length: 30 }, (_, index) => `B/review/r${index}/review.md`);
    expect(reviewPush(pushPayload({ commits: [{ added: many }] }))?.paths).toHaveLength(10);
  });
});

// --- GitHub, through the network edge ---------------------------------------------------

const app = { appID: "5963429", slug: "gitkittie-tasks", privateKey: rsaPKCS1PEM };

/** Answers like GitHub: an installation token for a valid App JWT, and files by ref. */
function github(files: Record<string, string>, seen: Request[] = []) {
  return async (request: Request): Promise<Response> => {
    seen.push(request.clone());
    const url = new URL(request.url);
    const auth = request.headers.get("authorization") ?? "";
    if (request.method === "POST" && url.pathname === "/app/installations/7/access_tokens") {
      const valid = await verifyJWT(auth.slice("Bearer ".length), rsa.publicKey, { name: "RSASSA-PKCS1-v1_5" });
      if (!valid) return new Response("{}", { status: 401 });
      return Response.json({ token: "ghs_installation" }, { status: 201 });
    }
    const contents = /^\/repos\/octo\/tasks\/contents\/(.+)$/.exec(url.pathname);
    if (contents && auth === "Bearer ghs_installation") {
      const text = files[`${url.searchParams.get("ref")}:${decodeURIComponent(contents[1]!)}`];
      return text === undefined ? new Response("", { status: 404 }) : new Response(text);
    }
    return new Response("{}", { status: 404 });
  };
}

describe("alertsForPush", () => {
  beforeEach(() => resetInstallationTokens());

  it("reads before and after as the App, limited to the repo and to reading contents", async () => {
    const seen: Request[] = [];
    const push = reviewPush(pushPayload())!;
    const alerts = await alertsForPush(push, app, github({ [`${"b".repeat(40)}:${PATH}`]: PENDING }, seen), 1_800_000_000);
    expect(alerts.map((alert) => [alert.title, alert.level])).toEqual([["Pet models, round 1", "urgent"]]);
    const tokenRequest = seen.find((request) => request.method === "POST")!;
    expect(await tokenRequest.json()).toEqual({ repository_ids: [42], permissions: { contents: "read" } });
    const reads = seen.filter((request) => request.method === "GET").map((request) => new URL(request.url).searchParams.get("ref"));
    expect(reads).toEqual(["b".repeat(40), "a".repeat(40)]);
    expect(seen.find((request) => request.method === "GET")!.headers.get("accept")).toBe("application/vnd.github.raw");
  });

  it("says nothing for a decision", async () => {
    const files = { [`${"a".repeat(40)}:${PATH}`]: PENDING, [`${"b".repeat(40)}:${PATH}`]: DECIDED };
    expect(await alertsForPush(reviewPush(pushPayload())!, app, github(files), 1_800_000_000)).toEqual([]);
  });

  it("says nothing when the App is not let in", async () => {
    const other = (await crypto.subtle.generateKey(
      { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
      true,
      ["sign"],
    )) as CryptoKeyPair;
    const wrongKey = { ...app, privateKey: pem("PRIVATE KEY", (await crypto.subtle.exportKey("pkcs8", other.privateKey)) as ArrayBuffer) };
    const files = { [`${"b".repeat(40)}:${PATH}`]: PENDING };
    expect(await alertsForPush(reviewPush(pushPayload())!, wrongKey, github(files), 1_800_000_000)).toEqual([]);
    expect(await alertsForPush(reviewPush(pushPayload({ installation: undefined }))!, app, github(files), 1_800_000_000)).toEqual([]);
  });
});

describe("registration checks", () => {
  it("accepts a person who can read the repo, and says where to install", async () => {
    const fetcher = async (request: Request): Promise<Response> => {
      if (request.headers.get("authorization") !== "Bearer gho_person") return new Response("{}", { status: 404 });
      return Response.json({ full_name: "octo/tasks", id: 42, owner: { id: 9 }, permissions: { pull: true } });
    };
    const repo = await readableRepo("gho_person", "octo/tasks", fetcher);
    expect(repo).toEqual({ repo: "octo/tasks", repoID: 42, ownerID: 9 });
    expect(await readableRepo("gho_stranger", "octo/tasks", fetcher)).toBeNull();
    expect(installURL(app, repo!)).toBe(
      "https://github.com/apps/gitkittie-tasks/installations/new/permissions?suggested_target_id=9&repository_ids[]=42",
    );
  });

  it("refuses a token that sees the repo without read permission", async () => {
    const fetcher = async (): Promise<Response> =>
      Response.json({ full_name: "octo/tasks", id: 42, owner: { id: 9 }, permissions: { pull: false } });
    expect(await readableRepo("gho_person", "octo/tasks", fetcher)).toBeNull();
  });

  it("asks GitHub as the App whether it is installed on the repo", async () => {
    const fetcher = async (request: Request): Promise<Response> => {
      const jwt = (request.headers.get("authorization") ?? "").slice("Bearer ".length);
      const ok = await verifyJWT(jwt, rsa.publicKey, { name: "RSASSA-PKCS1-v1_5" });
      if (!ok) return new Response("{}", { status: 401 });
      return new URL(request.url).pathname === "/repos/octo/tasks/installation"
        ? Response.json({ id: 7 })
        : new Response("{}", { status: 404 });
    };
    expect(await repoInstallation(app, "octo/tasks", fetcher, 1_800_000_000)).toBe(7);
    expect(await repoInstallation(app, "octo/other", fetcher, 1_800_000_000)).toBeNull();
    expect((await appJWT(app, 1_800_000_000)).split(".")).toHaveLength(3);
  });
});

// --- reviews for named people ------------------------------------------------------------

const ROOT_README = "---\nconfig: board\nusers:\n  - { id: sil, github: SilvanDiepen }\n  - { id: herma, github: herma-gh }\n  - { id: claude }\n---\n";
const BOARD_README = "---\nconfig: project\nusers:\n  - { id: herma, github: herma-new }\n---\n";

describe("reviews for named people", () => {
  const users = boardUsers(ROOT_README, BOARD_README);
  const FOR_SIL = PENDING.replace("notify: urgent\n", "notify: urgent\nfor: [sil]\n");
  const FOR_HERMA = PENDING.replace("notify: urgent\n", "notify: urgent\nfor: herma\n");

  it("reads the board's users, the board's own entry winning", () => {
    expect(users).toEqual([{ id: "sil", github: "SilvanDiepen" }, { id: "herma", github: "herma-new" }, { id: "claude", github: undefined }]);
    expect(boardUsers(null, "not frontmatter")).toEqual([]);
    expect(boardFolder("Clients/Acme/review/x/review.md")).toBe("Clients/Acme");
  });

  it("sends a request for someone only to their devices", async () => {
    const sil = await loginKey(42, "silvandiepen");
    const herma = await loginKey(42, "herma-new");
    const alert = (await reviewAlert("octo/tasks", PATH, null, FOR_SIL, { repoID: 42, users }))!;
    expect(alert.audience).toEqual({ mapped: [sil, herma], logins: [sil], others: false });
    const device = (token: string, key?: string): Device => ({ ...parseDevice({ token, platform: "ios", environment: "production" }, now)!, loginKey: key });
    const silsPhone = device("aa".repeat(32), sil);
    const hermasPhone = device("bb".repeat(32), herma);
    const unknown = device("cc".repeat(32));
    expect(recipients([silsPhone, hermasPhone, unknown], alert, now).map((d) => d.token)).toEqual([silsPhone.token]);
    // For everyone: every device, the ones without a login too.
    const everyone = (await reviewAlert("octo/tasks", PATH, null, PENDING, { repoID: 42, users }))!;
    expect(recipients([silsPhone, hermasPhone, unknown], everyone, now)).toHaveLength(3);
  });

  it("counts a request newly put on someone as new for them, and nobody else", async () => {
    const sil = await loginKey(42, "silvandiepen");
    const moved = (await reviewAlert("octo/tasks", PATH, FOR_HERMA, FOR_SIL, { repoID: 42, users }))!;
    expect(moved.audience.logins).toEqual([sil]);
    expect(await reviewAlert("octo/tasks", PATH, FOR_SIL, FOR_SIL.replace("Notes", "More notes"), { repoID: 42, users })).toBeNull();
    // A `for` id without a github login reaches nobody by push.
    const forClaude = PENDING.replace("notify: urgent\n", "for: claude\n");
    expect(await reviewAlert("octo/tasks", PATH, null, forClaude, { repoID: 42, users })).toBeNull();
  });

  it("reads the board's READMEs only for a request that names people", async () => {
    const seen: Request[] = [];
    const files = {
      [`${"b".repeat(40)}:${PATH}`]: FOR_SIL,
      [`${"b".repeat(40)}:README.md`]: ROOT_README,
      [`${"b".repeat(40)}:Morrow/README.md`]: BOARD_README,
    };
    const alerts = await alertsForPush(reviewPush(pushPayload())!, app, github(files, seen), 1_800_000_000);
    expect(alerts[0]?.audience.logins).toEqual([await loginKey(42, "silvandiepen")]);
    const paths = seen.filter((r) => r.method === "GET").map((r) => decodeURIComponent(new URL(r.url).pathname));
    expect(paths).toEqual([`/repos/octo/tasks/contents/${PATH}`, `/repos/octo/tasks/contents/${PATH}`,
                           "/repos/octo/tasks/contents/README.md", "/repos/octo/tasks/contents/Morrow/README.md"]);
  });

  it("records who registered as a key, from GET /user", async () => {
    const fetcher: Fetch = async (request) =>
      new URL(request.url).pathname === "/user" && request.headers.get("authorization") === "Bearer gho_person"
        ? Response.json({ login: "SilvanDiepen" })
        : new Response("{}", { status: 401 });
    expect(await userLogin("gho_person", fetcher)).toBe("SilvanDiepen");
    expect(await userLogin("gho_other", fetcher)).toBeNull();
    expect(await loginKey(42, "SilvanDiepen")).toBe(await loginKey(42, " silvandiepen "));
    expect(await loginKey(42, "silvandiepen")).not.toBe(await loginKey(43, "silvandiepen"));
  });
});

// --- devices and APNs -------------------------------------------------------------------

const TOKEN = "ab".repeat(32);
const now = new Date("2026-11-28T12:00:00Z");

describe("devices", () => {
  it("checks a registration", () => {
    const device = parseDevice({ token: TOKEN.toUpperCase(), platform: "ios", environment: "production", appVersion: "1.4.0" }, now);
    expect(device).toEqual({
      token: TOKEN,
      platform: "ios",
      environment: "production",
      levels: ["urgent", "normal", "silent"],
      appVersion: "1.4.0",
      verifiedAt: now.toISOString(),
    });
    expect(parseDevice({ token: "zz", platform: "ios", environment: "production" }, now)).toBeNull();
    expect(parseDevice({ token: TOKEN, platform: "android", environment: "production" }, now)).toBeNull();
    expect(parseDevice({ token: TOKEN, platform: "macos", environment: "dev" }, now)).toBeNull();
    expect(parseDevice({ token: TOKEN, platform: "macos", environment: "sandbox", levels: ["urgent", "loud"] }, now)?.levels).toEqual(["urgent"]);
  });

  it("sends a level only to devices that want it and still re-register", () => {
    const urgentOnly = parseDevice({ token: TOKEN, platform: "ios", environment: "production", levels: ["urgent", "silent"] }, now)!;
    const everything = parseDevice({ token: "cd".repeat(32), platform: "macos", environment: "sandbox" }, now)!;
    const stale = { ...everything, token: "ef".repeat(32), verifiedAt: "2026-09-01T00:00:00Z" };
    const alert = { level: "normal", audience: { mapped: [], logins: [], others: true } } as unknown as ReviewAlert;
    expect(recipients([urgentOnly, everything, stale], alert, now).map((device) => device.token)).toEqual([everything.token]);
    expect(isCurrent(stale, now)).toBe(false);
  });
});

const ALERT: ReviewAlert = {
  repo: "octo/tasks",
  path: PATH,
  folder: "Morrow/review/MORROW-182-pet-models",
  id: "MORROW-182-pet-models",
  board: "Morrow",
  title: "Pet models, round 1",
  level: "urgent",
  audience: { mapped: [], logins: [], others: true },
};
const DEVICE: Device = parseDevice({ token: TOKEN, platform: "ios", environment: "production" }, now)!;

describe("APNs requests", () => {
  it("makes an urgent alert time-sensitive, collapsed per review, with the review to open", async () => {
    const request = await alertRequest(ALERT, DEVICE, "jwt", "app.hakobs.gitkanban");
    expect(request.url).toBe(`https://api.push.apple.com/3/device/${TOKEN}`);
    expect(request.headers.get("authorization")).toBe("bearer jwt");
    expect(request.headers.get("apns-topic")).toBe("app.hakobs.gitkanban");
    expect(request.headers.get("apns-push-type")).toBe("alert");
    expect(request.headers.get("apns-priority")).toBe("10");
    expect(request.headers.get("apns-collapse-id")).toBe(await collapseID("octo/tasks", ALERT.folder));
    expect(request.headers.get("apns-collapse-id")!.length).toBeLessThanOrEqual(64);
    const body = (await request.json()) as { aps: Record<string, unknown>; review: Record<string, unknown> };
    expect(body.aps).toMatchObject({
      alert: { title: "Review: Pet models, round 1", body: "Morrow" },
      "interruption-level": "time-sensitive",
      category: "gitkanban.reviews",
      sound: "default",
    });
    expect(body.review).toEqual({ repo: "octo/tasks", folder: ALERT.folder, path: PATH, id: ALERT.id, board: "Morrow", level: "urgent" });
  });

  it("makes the same collapse id as the app's own notifications", async () => {
    // The same vector as ReviewPushTests in swift/GitKanbanKit (reviewNotificationID).
    expect(await collapseID("octo/tasks", "Morrow/review/MORROW-182-pet-models")).toBe("review-7c36cbb94ad4b1625df16e2c72184938");
  });

  it("makes a normal alert active, and a silent one a background wake with no alert", async () => {
    const normal = (await (await alertRequest({ ...ALERT, level: "normal" }, DEVICE, "jwt", "t")).json()) as { aps: Record<string, unknown> };
    expect(normal.aps["interruption-level"]).toBe("active");
    const silentRequest = await alertRequest({ ...ALERT, level: "silent" }, { ...DEVICE, environment: "sandbox" }, "jwt", "t");
    expect(silentRequest.url).toBe(`https://api.sandbox.push.apple.com/3/device/${TOKEN}`);
    expect(silentRequest.headers.get("apns-push-type")).toBe("background");
    expect(silentRequest.headers.get("apns-priority")).toBe("5");
    expect(((await silentRequest.json()) as { aps: unknown }).aps).toEqual({ "content-available": 1 });
    const wake = wakeRequest("group/tasks", DEVICE, "jwt", "t");
    expect(wake.headers.get("apns-push-type")).toBe("background");
    expect(await wake.json()).toEqual({ aps: { "content-available": 1 }, reviewsChanged: { repo: "group/tasks" } });
  });

  it("reads Apple's answers: sent, gone, failed", async () => {
    const request = await alertRequest(ALERT, DEVICE, "jwt", "t");
    const answer = (status: number, body = "") => async () => new Response(body, { status });
    expect(await send(request.clone(), answer(200))).toBe("sent");
    expect(await send(request.clone(), answer(410, '{"reason":"Unregistered"}'))).toBe("gone");
    expect(await send(request.clone(), answer(400, '{"reason":"BadDeviceToken"}'))).toBe("gone");
    expect(await send(request.clone(), answer(400, '{"reason":"PayloadTooLarge"}'))).toBe("failed");
    expect(await send(request.clone(), answer(403, '{"reason":"InvalidProviderToken"}'))).toBe("failed");
  });
});
