import { isAbsolute } from "node:path";

export interface ServerConfig {
  /** Absolute folder that is served. */
  root: string;
  port: number;
  host: string;
  /** When non-empty, `/api/*` (except health) requires a matching `Tailscale-User-Login`. */
  allowedLogins: string[];
  /** Announce on Bonjour so the apps can find the server (GKS_ANNOUNCE, default on). */
  announce: boolean;
  /** Address to advertise instead of the detected Tailscale HTTPS name (GKS_PUBLIC_URL). */
  publicUrl?: string;
  /** Name shown in the apps (GKS_NAME, default "<folder> on <computer name>"). */
  name?: string;
}

export const DEFAULT_PORT = 4417;
export const DEFAULT_HOST = "127.0.0.1";

/** Reads `GKS_*` env vars. Throws with a readable message on invalid input. */
export function loadConfig(env: NodeJS.ProcessEnv): ServerConfig {
  const root = env.GKS_ROOT?.trim();
  if (!root) {
    throw new Error("GKS_ROOT is required (absolute path of the folder to serve).");
  }
  if (!isAbsolute(root)) {
    throw new Error(`GKS_ROOT must be an absolute path, got "${root}".`);
  }

  const portRaw = env.GKS_PORT?.trim();
  const port = portRaw ? Number(portRaw) : DEFAULT_PORT;
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`GKS_PORT must be an integer between 1 and 65535, got "${portRaw}".`);
  }

  const host = env.GKS_HOST?.trim() || DEFAULT_HOST;

  const allowedLogins = (env.GKS_ALLOWED_LOGINS ?? "")
    .split(",")
    .map((login) => login.trim())
    .filter((login) => login.length > 0);

  const announceRaw = env.GKS_ANNOUNCE?.trim().toLowerCase();
  const announce = !(announceRaw === "0" || announceRaw === "false" || announceRaw === "no");

  const publicUrlRaw = env.GKS_PUBLIC_URL?.trim().replace(/\/+$/, "");
  if (publicUrlRaw && !/^https?:\/\/[^/\s]+/.test(publicUrlRaw)) {
    throw new Error(`GKS_PUBLIC_URL must be an http(s) URL, got "${publicUrlRaw}".`);
  }
  const name = env.GKS_NAME?.trim() || undefined;

  return {
    root,
    port,
    host,
    allowedLogins,
    announce,
    ...(publicUrlRaw ? { publicUrl: publicUrlRaw } : {}),
    ...(name ? { name } : {}),
  };
}
