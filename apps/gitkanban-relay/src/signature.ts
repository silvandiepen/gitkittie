// GitHub signs each webhook body with the secret the hook was created with
// (`X-Hub-Signature-256: sha256=<hex hmac>`); GitLab sends the secret itself
// (`X-Gitlab-Token`). Nothing is relayed without a valid one. The apps prove a
// channel registration comes from a GitKittie client with `clientProof`.

const encoder = new TextEncoder();

function hexToBytes(hex: string): Uint8Array | null {
  if (hex.length === 0 || hex.length % 2 !== 0 || !/^[0-9a-f]+$/i.test(hex)) return null;
  const bytes = new Uint8Array(hex.length / 2);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = Number.parseInt(hex.slice(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

async function key(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
    "verify",
  ]);
}

/** The header value GitHub would send for `body` signed with `secret`. */
export async function sign(secret: string, body: string): Promise<string> {
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", await key(secret), encoder.encode(body)));
  return `sha256=${[...mac].map((byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

/** Whether `header` is a valid signature of `body`. Compared in constant time by WebCrypto. */
export async function verify(secret: string, body: string, header: string | null | undefined): Promise<boolean> {
  if (!header?.startsWith("sha256=")) return false;
  const mac = hexToBytes(header.slice("sha256=".length));
  if (!mac) return false;
  return crypto.subtle.verify("HMAC", await key(secret), mac, encoder.encode(body));
}

/** A random secret as hex. */
export function randomHex(bytes: number): string {
  return [...crypto.getRandomValues(new Uint8Array(bytes))].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** Constant-time comparison of two short secrets, for the subscribe key. */
export async function sameSecret(a: string, b: string): Promise<boolean> {
  const [left, right] = await Promise.all([sign("compare", a), sign("compare", b)]);
  return left === right;
}

/**
 * What every GitKittie client (Tasks, GitFolder, ...) and this relay are built with. It is
 * in the apps and in this source, so it is not a secret: it tells the family's clients from
 * anything that merely found the relay's address, and nothing more.
 */
export const CLIENT_FAMILY = "gitkittie-client-v1:dcdbb50e99dd24b424c6ddea8c6eb7446dc199b802ff7346";

/** How far a client's clock may be off, and so how long a captured registration can be replayed. */
export const REGISTRATION_WINDOW_SECONDS = 300;

/**
 * The `X-GitKanban-Client` header: the install's own random id, the time, and the hash that
 * ties them and the body to the client family: `id=<id>,t=<unix seconds>,v1=<hex HMAC-SHA256
 * of "<id>.<t>.<body>" keyed with CLIENT_FAMILY>`.
 */
export async function clientProof(clientID: string, body: string, time: number): Promise<string> {
  const mac = await sign(CLIENT_FAMILY, `${clientID}.${time}.${body}`);
  return `id=${clientID},t=${time},v1=${mac.slice("sha256=".length)}`;
}

/** The client id when `header` is a fresh, valid proof for `body`; otherwise `null`. `now` is unix seconds. */
export async function verifiedClient(body: string, header: string | null | undefined, now: number): Promise<string | null> {
  const match = /^id=([0-9a-f]{32}),t=(\d{1,12}),v1=([0-9a-f]{64})$/.exec(header ?? "");
  if (!match) return null;
  const [, clientID, time, mac] = match;
  if (Math.abs(now - Number(time)) > REGISTRATION_WINDOW_SECONDS) return null;
  return (await verify(CLIENT_FAMILY, `${clientID}.${time}.${body}`, `sha256=${mac}`)) ? clientID! : null;
}
