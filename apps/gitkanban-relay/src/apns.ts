// Apple Push Notification service: token-based auth (an ES256 JWT from the .p8 key, reused
// for up to 50 minutes as Apple asks) and one HTTP/2 request per device.

import { apnsToken, importES256 } from "./jwt.js";
import type { ReviewAlert } from "./review-push.js";

export interface APNsConfig {
  keyID: string;
  teamID: string;
  /** The .p8 key's PEM text, from the `APNS_PRIVATE_KEY` secret. */
  privateKey: string;
  /** The app's bundle id. */
  topic: string;
}

/** A registered device. */
export interface Device {
  token: string;
  platform: "ios" | "macos";
  /** `sandbox` for builds signed for development, `production` for TestFlight and the App Store. */
  environment: "production" | "sandbox";
  /** The levels this device wants an alert for; a level left out is not sent. */
  levels: Array<"urgent" | "normal" | "silent">;
  appVersion: string;
  /** When the device last proved it may read the repo (ISO-8601). */
  verifiedAt: string;
}

export type Fetch = (input: Request) => Promise<Response>;

const HOSTS = { production: "https://api.push.apple.com", sandbox: "https://api.sandbox.push.apple.com" } as const;
/** Apple refuses tokens older than an hour and throttles making new ones more often than every 20 minutes. */
const TOKEN_LIFETIME_SECONDS = 50 * 60;

let cached: { key: string; token: string; issuedAt: number } | null = null;

/** The provider token, made again when it is 50 minutes old or the key changed. */
export async function providerToken(config: APNsConfig, now: number): Promise<string> {
  const cacheKey = `${config.keyID}.${config.teamID}`;
  if (cached && cached.key === cacheKey && now - cached.issuedAt < TOKEN_LIFETIME_SECONDS) return cached.token;
  const token = await apnsToken(await importES256(config.privateKey), config.keyID, config.teamID, now);
  cached = { key: cacheKey, token, issuedAt: now };
  return token;
}

/** For tests: forget the cached provider token. */
export function resetProviderToken(): void {
  cached = null;
}

/** What a device token looks like: hex, 32 bytes today, longer allowed. */
export const DEVICE_TOKEN = /^[0-9a-f]{64,200}$/;

/** The apns-collapse-id for a review (at most 64 bytes): `review-` + 32 hex of SHA-256(repo|folder). */
export async function collapseID(repo: string, folder: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${repo}|${folder}`)));
  return `review-${[...digest.slice(0, 16)].map((byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

/** The request that announces `alert` on `device`. */
export async function alertRequest(alert: ReviewAlert, device: Device, token: string, topic: string): Promise<Request> {
  const silent = alert.level === "silent";
  const aps: Record<string, unknown> = silent
    ? // Badge and Reviews list only: no alert, the app wakes, reloads its inbox and badge.
      { "content-available": 1 }
    : {
        alert: { title: `Review: ${alert.title}`, body: alert.board },
        sound: "default",
        "interruption-level": alert.level === "urgent" ? "time-sensitive" : "active",
        "thread-id": "gitkanban.reviews",
        category: "gitkanban.reviews",
        // Lets a running or suspended app reload its inbox and badge, and note the review as announced.
        "content-available": 1,
      };
  const body = JSON.stringify({
    aps,
    review: { repo: alert.repo, folder: alert.folder, path: alert.path, id: alert.id, board: alert.board, level: alert.level },
  });
  return new Request(`${HOSTS[device.environment]}/3/device/${device.token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${token}`,
      "apns-topic": topic,
      "apns-push-type": silent ? "background" : "alert",
      // Background pushes must go at priority 5; alerts at 10 are delivered at once.
      "apns-priority": silent ? "5" : "10",
      "apns-collapse-id": await collapseID(alert.repo, alert.folder),
      // Worth delivering for a day if the device is off; after that the app's own check finds it.
      "apns-expiration": String(Math.floor(Date.now() / 1000) + 86_400),
      "content-type": "application/json",
    },
    body,
  });
}

/** A wake-up for a repo whose reviews changed but whose files the relay cannot read (GitLab channels). */
export function wakeRequest(repo: string, device: Device, token: string, topic: string): Request {
  return new Request(`${HOSTS[device.environment]}/3/device/${device.token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${token}`,
      "apns-topic": topic,
      "apns-push-type": "background",
      "apns-priority": "5",
      "content-type": "application/json",
    },
    body: JSON.stringify({ aps: { "content-available": 1 }, reviewsChanged: { repo } }),
  });
}

export type SendOutcome = "sent" | "gone" | "failed";

/**
 * Send one request. `gone` means Apple says the token is no longer valid for this app
 * (410, or 400 BadDeviceToken / DeviceTokenNotForTopic), and the device should be forgotten.
 */
export async function send(request: Request, fetcher: Fetch): Promise<SendOutcome> {
  const response = await fetcher(request);
  if (response.status === 200) return "sent";
  if (response.status === 410) return "gone";
  if (response.status === 400) {
    const reason = ((await response.json().catch(() => ({}))) as { reason?: string }).reason;
    if (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic") return "gone";
  }
  return "failed";
}
