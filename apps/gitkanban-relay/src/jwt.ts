// JSON Web Tokens the relay signs for itself: ES256 for Apple's push service (the .p8 key)
// and RS256 for GitHub (the GitHub App's private key). WebCrypto only, no dependencies.
// The keys come from Worker secrets; nothing here logs or returns them.

const encoder = new TextEncoder();

export function base64url(bytes: Uint8Array | string): string {
  const data = typeof bytes === "string" ? encoder.encode(bytes) : bytes;
  let binary = "";
  for (const byte of data) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** The DER bytes and label of a PEM block (`-----BEGIN <label>-----`). */
export function pemBody(pem: string): { label: string; der: Uint8Array } {
  const match = /-----BEGIN ([A-Z ]+)-----([\s\S]+?)-----END \1-----/.exec(pem.replace(/\\n/g, "\n"));
  if (!match) throw new Error("not a PEM key");
  const binary = atob(match[2]!.replace(/\s+/g, ""));
  const der = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) der[index] = binary.charCodeAt(index);
  return { label: match[1]!, der };
}

function derLength(length: number): number[] {
  if (length < 0x80) return [length];
  const bytes: number[] = [];
  for (let rest = length; rest > 0; rest >>= 8) bytes.unshift(rest & 0xff);
  return [0x80 | bytes.length, ...bytes];
}

function der(tag: number, content: Uint8Array | number[]): Uint8Array {
  const body = content instanceof Uint8Array ? [...content] : content;
  return new Uint8Array([tag, ...derLength(body.length), ...body]);
}

/**
 * GitHub hands out App keys as PKCS#1 (`BEGIN RSA PRIVATE KEY`); WebCrypto imports PKCS#8.
 * PKCS#8 is PKCS#1 wrapped in a version and the rsaEncryption algorithm identifier.
 */
export function pkcs1ToPkcs8(pkcs1: Uint8Array): Uint8Array {
  const version = [0x02, 0x01, 0x00];
  // SEQUENCE { OID 1.2.840.113549.1.1.1, NULL }
  const algorithm = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00];
  const key = der(0x04, pkcs1);
  return der(0x30, [...version, ...algorithm, ...key]);
}

async function sign(header: object, claims: object, key: CryptoKey, algorithm: Parameters<SubtleCrypto["sign"]>[0]): Promise<string> {
  const input = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(claims))}`;
  // WebCrypto's ECDSA output is r||s (IEEE P1363), which is what JWS wants for ES256.
  const signature = new Uint8Array(await crypto.subtle.sign(algorithm, key, encoder.encode(input)));
  return `${input}.${base64url(signature)}`;
}

export async function importES256(pem: string): Promise<CryptoKey> {
  const { der: pkcs8 } = pemBody(pem);
  return crypto.subtle.importKey("pkcs8", pkcs8, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

export async function importRS256(pem: string): Promise<CryptoKey> {
  const { label, der: body } = pemBody(pem);
  const pkcs8 = label === "RSA PRIVATE KEY" ? pkcs1ToPkcs8(body) : body;
  return crypto.subtle.importKey("pkcs8", pkcs8, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
}

/** APNs provider token: `{alg: ES256, kid}` / `{iss: team, iat}`. `now` is unix seconds. */
export function apnsToken(key: CryptoKey, keyID: string, teamID: string, now: number): Promise<string> {
  return sign({ alg: "ES256", kid: keyID }, { iss: teamID, iat: now }, key, { name: "ECDSA", hash: "SHA-256" });
}

/**
 * GitHub App token: issued a minute in the past (clock drift), valid for nine minutes (GitHub
 * allows ten). `now` is unix seconds.
 */
export function githubAppToken(key: CryptoKey, appID: string, now: number): Promise<string> {
  return sign({ alg: "RS256", typ: "JWT" }, { iss: appID, iat: now - 60, exp: now + 540 }, key, { name: "RSASSA-PKCS1-v1_5" });
}
