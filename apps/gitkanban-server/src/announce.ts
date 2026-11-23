import { execFile, execFileSync, spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { hostname } from "node:os";

/**
 * Bonjour announcement, so the GitKanban apps can list this server without anyone typing
 * an address.
 *
 * The server itself stays bound to localhost. The announcement only *points* at it: its
 * TXT record carries the address the apps should use, normally the Mac's Tailscale HTTPS
 * name (`tailscale serve` in front of the server). A phone on the same network sees the
 * announcement, saves that address, and keeps using it over Tailscale when it's away.
 *
 * Uses macOS's built-in `dns-sd`, so there is no extra dependency or daemon.
 */

export const SERVICE_TYPE = "_gitkanban._tcp";
const DNS_SD = "/usr/bin/dns-sd";
const RECHECK_MS = 5 * 60 * 1000;
const RESTART_MS = 10 * 1000;

export interface AnnounceOptions {
  /** Shown in the apps, e.g. "Projects on Sil's MacBook Pro". */
  name: string;
  /** The served folder's name (`root` in TXT). */
  root: string;
  /** Local port, advertised for completeness; the apps use `url`. */
  port: number;
  /** Fixed address to advertise. When unset, the Tailscale HTTPS name is detected. */
  publicUrl?: string;
}

/** The TXT key/value pairs for an announcement. `url` is omitted when there's no reachable address yet. */
export function txtRecord(options: { root: string; url?: string }): string[] {
  const entries = [`v=1`, `root=${options.root}`];
  if (options.url) entries.push(`url=${options.url}`);
  return entries;
}

/** `dns-sd -R` arguments for an announcement. */
export function dnsSdArgs(options: AnnounceOptions, url: string | undefined): string[] {
  return ["-R", options.name, SERVICE_TYPE, "local", String(options.port), ...txtRecord({ root: options.root, url })];
}

/** The HTTPS address `tailscale serve` gives this machine, from `tailscale status --json` output. */
export function tailnetUrlFromStatus(json: string): string | undefined {
  try {
    const status = JSON.parse(json) as { BackendState?: string; Self?: { DNSName?: string } };
    if (status.BackendState !== "Running") return undefined;
    const dnsName = status.Self?.DNSName?.replace(/\.$/, "");
    return dnsName ? `https://${dnsName}` : undefined;
  } catch {
    // Not JSON (older CLI, or an error message on stdout): no address to advertise.
    return undefined;
  }
}

const TAILSCALE_CANDIDATES = [
  "/opt/homebrew/bin/tailscale",
  "/usr/local/bin/tailscale",
  "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
];

function findTailscale(): string | undefined {
  return TAILSCALE_CANDIDATES.find((path) => existsSync(path));
}

function detectTailnetUrl(): Promise<string | undefined> {
  const cli = findTailscale();
  if (!cli) return Promise.resolve(undefined);
  return new Promise((resolve) => {
    execFile(cli, ["status", "--json"], { timeout: 10_000 }, (error, stdout) => {
      // A version-mismatch warning goes to stderr with exit 0; a stopped Tailscale exits non-zero.
      resolve(error ? undefined : tailnetUrlFromStatus(stdout));
    });
  });
}

/** The Mac's user-facing name ("Sil's MacBook Pro"), falling back to the host name. */
export function computerName(): string {
  try {
    const name = execFileSync("/usr/sbin/scutil", ["--get", "ComputerName"], { encoding: "utf8", timeout: 5000 }).trim();
    if (name.length > 0) return name;
  } catch (error) {
    console.warn(`[gitkanban-server] scutil --get ComputerName failed, using the host name: ${String(error)}`);
  }
  return hostname().replace(/\.local$/, "");
}

/** The default display name: "<folder> on <computer name>". */
export function defaultServiceName(root: string, computer: string): string {
  return `${root} on ${computer}`;
}

export interface Announcer {
  stop(): void;
}

/**
 * Start announcing. Re-checks the Tailscale address every few minutes (Tailscale may start
 * after the server) and restarts `dns-sd` if it exits.
 */
export function startAnnouncing(options: AnnounceOptions, log: (message: string) => void): Announcer {
  if (!existsSync(DNS_SD)) {
    log(`not announcing on Bonjour: ${DNS_SD} not found`);
    return { stop() {} };
  }

  let child: ChildProcess | undefined;
  let currentUrl: string | undefined;
  let stopped = false;
  let restartTimer: NodeJS.Timeout | undefined;

  const launch = (): void => {
    if (stopped) return;
    const proc = spawn(DNS_SD, dnsSdArgs(options, currentUrl), { stdio: "ignore" });
    child = proc;
    proc.on("error", (error) => log(`dns-sd failed: ${error.message}`));
    proc.on("exit", () => {
      if (child === proc) child = undefined;
      if (!stopped && !restartTimer) {
        restartTimer = setTimeout(() => {
          restartTimer = undefined;
          if (!child) launch();
        }, RESTART_MS);
        restartTimer.unref();
      }
    });
    log(`announcing "${options.name}" (${SERVICE_TYPE})${currentUrl ? ` → ${currentUrl}` : ", no reachable address yet"}`);
  };

  const refresh = async (): Promise<void> => {
    const url = options.publicUrl ?? (await detectTailnetUrl());
    if (stopped) return;
    if (child && url === currentUrl) return;
    currentUrl = url;
    if (child) {
      const old = child;
      child = undefined;
      old.kill();
    }
    launch();
  };

  void refresh();
  const recheck = setInterval(() => void refresh(), RECHECK_MS);
  recheck.unref();

  return {
    stop() {
      stopped = true;
      clearInterval(recheck);
      if (restartTimer) clearTimeout(restartTimer);
      child?.kill();
      child = undefined;
    },
  };
}
