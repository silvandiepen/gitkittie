// Devices that want push notifications for a repository: what a registration must look
// like, and which devices a given alert goes to.

import { DEVICE_TOKEN, type Device } from "./apns.js";
import type { ReviewAlert } from "./review-push.js";

/** A device that has not proved repo access again for this long is dropped (the app re-registers at launch). */
export const DEVICE_LIFETIME_DAYS = 45;
/** More devices than this on one repository is not one person's phones and Macs. */
export const MAX_DEVICES_PER_REPO = 50;

const LEVELS = ["urgent", "normal", "silent"] as const;

/** A registration as the app sends it, checked; `null` when anything is off. */
export function parseDevice(value: unknown, now: Date): Device | null {
  if (typeof value !== "object" || value === null) return null;
  const raw = value as Record<string, unknown>;
  const token = typeof raw.token === "string" ? raw.token.toLowerCase() : "";
  if (!DEVICE_TOKEN.test(token)) return null;
  if (raw.platform !== "ios" && raw.platform !== "macos") return null;
  if (raw.environment !== "production" && raw.environment !== "sandbox") return null;
  const levels = Array.isArray(raw.levels)
    ? LEVELS.filter((level) => (raw.levels as unknown[]).includes(level))
    : [...LEVELS];
  const appVersion = typeof raw.appVersion === "string" ? raw.appVersion.slice(0, 32) : "";
  return { token, platform: raw.platform, environment: raw.environment, levels, appVersion, verifiedAt: now.toISOString() };
}

/** Whether `device` registered (proved access) recently enough to still be sent to. */
export function isCurrent(device: Device, now: Date): boolean {
  const verified = Date.parse(device.verifiedAt);
  return Number.isFinite(verified) && now.getTime() - verified < DEVICE_LIFETIME_DAYS * 86_400_000;
}

/**
 * The devices that want `alert`: current, at its level, and in its audience. A device whose
 * person is one of the board's users (by `github:`) gets it when something newly waits for that
 * user; any other device (no login recorded, or nobody on the board) when something newly waits
 * for everyone.
 */
export function recipients(devices: Device[], alert: ReviewAlert, now: Date): Device[] {
  return devices.filter((device) => {
    if (!isCurrent(device, now) || !device.levels.includes(alert.level)) return false;
    const key = device.loginKey;
    if (key && alert.audience.mapped.includes(key)) return alert.audience.logins.includes(key);
    return alert.audience.others;
  });
}

/** What a device's person is known by on a repo: SHA-256 hex of `<repo id>:<login>`, login in lower case. */
export async function loginKey(repoID: number, login: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${repoID}:${login.trim().toLowerCase()}`));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
