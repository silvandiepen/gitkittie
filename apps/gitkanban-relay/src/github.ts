// The relay as the "GitKittie Tasks" GitHub App: it signs a JWT with the App's private key,
// trades it for an installation token limited to one repository and to reading contents,
// and reads a review file with it. It also checks, for a device registration, that the
// person's own token can read the repository; that token is used for that one call and
// never kept.

import { githubAppToken, importRS256 } from "./jwt.js";
import type { Fetch } from "./apns.js";

export interface GitHubAppConfig {
  appID: string;
  /** The App's private key (PEM, PKCS#1 as GitHub gives it, or PKCS#8). */
  privateKey: string;
  slug: string;
}

const API = "https://api.github.com";
const USER_AGENT = "gitkanban-relay";

function headers(token: string, accept = "application/vnd.github+json"): HeadersInit {
  return { authorization: `Bearer ${token}`, accept, "user-agent": USER_AGENT, "x-github-api-version": "2022-11-28" };
}

export async function appJWT(config: GitHubAppConfig, now: number): Promise<string> {
  return githubAppToken(await importRS256(config.privateKey), config.appID, now);
}

/** Installation tokens live an hour; keep each for 50 minutes, per installation and repository. */
const tokenCache = new Map<string, { token: string; until: number }>();

export function resetInstallationTokens(): void {
  tokenCache.clear();
}

/** A token that can read the contents of `repoID` (and nothing else) through installation `installationID`. */
export async function installationToken(
  config: GitHubAppConfig,
  installationID: number,
  repoID: number,
  fetcher: Fetch,
  now: number,
): Promise<string | null> {
  const cacheKey = `${installationID}:${repoID}`;
  const hit = tokenCache.get(cacheKey);
  if (hit && hit.until > now) return hit.token;
  const response = await fetcher(
    new Request(`${API}/app/installations/${installationID}/access_tokens`, {
      method: "POST",
      headers: { ...headers(await appJWT(config, now)), "content-type": "application/json" },
      body: JSON.stringify({ repository_ids: [repoID], permissions: { contents: "read" } }),
    }),
  );
  if (response.status !== 201) return null;
  const { token } = (await response.json()) as { token?: string };
  if (typeof token !== "string") return null;
  tokenCache.set(cacheKey, { token, until: now + 50 * 60 });
  return token;
}

/** A file's text at `ref`, or `null` when it is not there (or cannot be read). */
export async function fileAt(token: string, repo: string, path: string, ref: string, fetcher: Fetch): Promise<string | null> {
  const encoded = path.split("/").map(encodeURIComponent).join("/");
  const response = await fetcher(
    new Request(`${API}/repos/${repo}/contents/${encoded}?ref=${encodeURIComponent(ref)}`, {
      headers: headers(token, "application/vnd.github.raw"),
    }),
  );
  return response.status === 200 ? response.text() : null;
}

/** What GitHub says about a repository the person's token can read. */
export interface ReadableRepo {
  repo: string;
  repoID: number;
  ownerID: number;
}

/** The repository, when `userToken` may read it (`permissions.pull`); otherwise `null`. */
export async function readableRepo(userToken: string, repo: string, fetcher: Fetch): Promise<ReadableRepo | null> {
  const response = await fetcher(new Request(`${API}/repos/${repo}`, { headers: headers(userToken) }));
  if (response.status !== 200) return null;
  const body = (await response.json()) as {
    full_name?: unknown;
    id?: unknown;
    owner?: { id?: unknown };
    permissions?: { pull?: unknown };
  };
  if (typeof body.id !== "number" || typeof body.full_name !== "string" || typeof body.owner?.id !== "number") return null;
  if (body.permissions?.pull !== true) return null;
  return { repo: body.full_name, repoID: body.id, ownerID: body.owner.id };
}

/** The App's installation on `repo`, or `null` when the App is not installed there. */
export async function repoInstallation(config: GitHubAppConfig, repo: string, fetcher: Fetch, now: number): Promise<number | null> {
  const response = await fetcher(new Request(`${API}/repos/${repo}/installation`, { headers: headers(await appJWT(config, now)) }));
  if (response.status !== 200) return null;
  const { id } = (await response.json()) as { id?: unknown };
  return typeof id === "number" ? id : null;
}

/** Where a person installs the App on `repo`, with the account and repository chosen for them. */
export function installURL(config: GitHubAppConfig, repo: ReadableRepo): string {
  return `https://github.com/apps/${config.slug}/installations/new/permissions?suggested_target_id=${repo.ownerID}&repository_ids[]=${repo.repoID}`;
}
