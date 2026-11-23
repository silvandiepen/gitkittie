import { readFile, readdir, stat, symlink } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import { SharedWatcher } from "../src/watcher.js";
import { makeTempDir, type TempDir } from "./helpers.js";

let root: TempDir;
let outside: TempDir;

beforeEach(async () => {
  root = await makeTempDir();
  outside = await makeTempDir("gks-outside-");
  await root.write("Tasks/README.md", "# Tasks\n");
  await root.write("Tasks/1. To do/card.md", "---\nstatus: todo\n---\n");
  await root.write("image.png", new Uint8Array([0x89, 0x50, 0x4e, 0x47]));
  await root.write("digits.txt", "0123456789");
  await root.write(".env", "SECRET=1");
  await root.write(".git/config", "[core]");
  await root.write("node_modules/x/index.js", "");
  await root.write(".DS_Store", "");
  await outside.write("secret.txt", "outside");
});

afterEach(async () => {
  await root.cleanup();
  await outside.cleanup();
});

function app(allowedLogins: string[] = []) {
  return createApp({ root: root.path, allowedLogins });
}

function q(path: string): string {
  return encodeURIComponent(path);
}

describe("health and whoami", () => {
  it("reports ok and the root basename", async () => {
    const res = await app().request("/api/health");
    expect(res.status).toBe(200);
    const body = (await res.json()) as { ok: boolean; root: string };
    expect(body.ok).toBe(true);
    expect(root.path.endsWith(body.root)).toBe(true);
  });

  it("echoes Tailscale identity headers, decoding RFC 2047 names", async () => {
    const res = await app().request("/api/whoami", {
      headers: { "Tailscale-User-Login": "sil@example.com", "Tailscale-User-Name": "=?utf-8?q?Sil_van_Di=C3=ABpen?=" },
    });
    expect(await res.json()).toEqual({ login: "sil@example.com", name: "Sil van Diëpen" });
  });

  it("returns nulls without identity headers", async () => {
    const res = await app().request("/api/whoami");
    expect(await res.json()).toEqual({ login: null, name: null });
  });
});

describe("login allowlist", () => {
  it("rejects /api/* without an allowed login", async () => {
    const a = app(["sil@example.com"]);
    expect((await a.request("/api/list?path=")).status).toBe(403);
    expect(
      (await a.request("/api/list?path=", { headers: { "Tailscale-User-Login": "eve@example.com" } })).status,
    ).toBe(403);
  });

  it("allows an allowed login and leaves health open", async () => {
    const a = app(["other@example.com", "sil@example.com"]);
    const res = await a.request("/api/list?path=", { headers: { "Tailscale-User-Login": "sil@example.com" } });
    expect(res.status).toBe(200);
    expect((await a.request("/api/health")).status).toBe(200);
  });
});

describe("GET /api/list", () => {
  it("lists the root, skipping dotfiles and node_modules", async () => {
    const res = await app().request("/api/list?path=");
    expect(res.status).toBe(200);
    const entries = (await res.json()) as { name: string; path: string; kind: string; size: number; mtime: string }[];
    expect(entries.map((e) => e.name)).toEqual(["Tasks", "digits.txt", "image.png"]);
    const digits = entries.find((e) => e.name === "digits.txt");
    expect(digits).toMatchObject({ path: "digits.txt", kind: "file", size: 10 });
    expect(new Date(digits!.mtime).toISOString()).toBe(digits!.mtime);
    expect(entries.find((e) => e.name === "Tasks")).toMatchObject({ kind: "directory", path: "Tasks" });
  });

  it("lists a nested directory with root-relative paths", async () => {
    const res = await app().request(`/api/list?path=${q("Tasks")}`);
    const entries = (await res.json()) as { path: string }[];
    expect(entries.map((e) => e.path)).toEqual(["Tasks/1. To do", "Tasks/README.md"]);
  });

  it("treats a missing path param as the root", async () => {
    expect((await app().request("/api/list")).status).toBe(200);
  });

  it("404s a missing dir and 400s a file", async () => {
    expect((await app().request("/api/list?path=nope")).status).toBe(404);
    expect((await app().request("/api/list?path=digits.txt")).status).toBe(400);
  });

  it("omits symlinks that escape the root", async () => {
    await symlink(outside.path, join(root.path, "escape"));
    await symlink(join(root.path, "digits.txt"), join(root.path, "inside-link.txt"));
    const entries = (await (await app().request("/api/list?path=")).json()) as { name: string }[];
    expect(entries.map((e) => e.name)).not.toContain("escape");
    expect(entries.map((e) => e.name)).toContain("inside-link.txt");
  });
});

describe("GET /api/file", () => {
  it("serves bytes with content type, ETag, Last-Modified and Accept-Ranges", async () => {
    const res = await app().request(`/api/file?path=${q("Tasks/README.md")}`);
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("text/markdown; charset=utf-8");
    expect(res.headers.get("ETag")).toMatch(/^"[0-9a-f]+-[0-9a-f]+"$/);
    expect(res.headers.get("Last-Modified")).toBeTruthy();
    expect(res.headers.get("Accept-Ranges")).toBe("bytes");
    expect(await res.text()).toBe("# Tasks\n");

    const png = await app().request("/api/file?path=image.png");
    expect(png.headers.get("Content-Type")).toBe("image/png");
    expect(new Uint8Array(await png.arrayBuffer())).toEqual(new Uint8Array([0x89, 0x50, 0x4e, 0x47]));
  });

  it("returns 304 for a matching If-None-Match", async () => {
    const a = app();
    const first = await a.request("/api/file?path=digits.txt");
    const etag = first.headers.get("ETag")!;
    await first.arrayBuffer();
    const second = await a.request("/api/file?path=digits.txt", { headers: { "If-None-Match": etag } });
    expect(second.status).toBe(304);
    expect(second.headers.get("ETag")).toBe(etag);
    const stale = await a.request("/api/file?path=digits.txt", { headers: { "If-None-Match": '"0-0"' } });
    expect(stale.status).toBe(200);
  });

  it.each([
    ["bytes=2-5", "2345", "bytes 2-5/10"],
    ["bytes=7-", "789", "bytes 7-9/10"],
    ["bytes=-3", "789", "bytes 7-9/10"],
    ["bytes=8-100", "89", "bytes 8-9/10"],
  ])("serves Range %s as 206", async (range, body, contentRange) => {
    const res = await app().request("/api/file?path=digits.txt", { headers: { Range: range } });
    expect(res.status).toBe(206);
    expect(res.headers.get("Content-Range")).toBe(contentRange);
    expect(res.headers.get("Content-Length")).toBe(String(body.length));
    expect(await res.text()).toBe(body);
  });

  it("returns 416 for an unsatisfiable range", async () => {
    const res = await app().request("/api/file?path=digits.txt", { headers: { Range: "bytes=10-20" } });
    expect(res.status).toBe(416);
    expect(res.headers.get("Content-Range")).toBe("bytes */10");
  });

  it("404s missing files and 400s directories", async () => {
    expect((await app().request("/api/file?path=missing.md")).status).toBe(404);
    expect((await app().request("/api/file?path=Tasks")).status).toBe(400);
  });

  it("answers HEAD with headers and no body", async () => {
    const res = await app().request("/api/file?path=digits.txt", { method: "HEAD" });
    expect(res.status).toBe(200);
    expect(res.headers.get("ETag")).toBeTruthy();
    expect(await res.text()).toBe("");
  });
});

describe("PUT /api/file", () => {
  it("creates a file and its parent directories, returning the new ETag", async () => {
    const a = app();
    const res = await a.request(`/api/file?path=${q("new/deep/card.md")}`, { method: "PUT", body: "hello" });
    expect(res.status).toBe(200);
    const { etag } = (await res.json()) as { etag: string };
    expect(await readFile(join(root.path, "new/deep/card.md"), "utf8")).toBe("hello");
    const get = await a.request(`/api/file?path=${q("new/deep/card.md")}`);
    expect(get.headers.get("ETag")).toBe(etag);
  });

  it("leaves no temp files behind", async () => {
    await app().request("/api/file?path=Tasks/README.md", { method: "PUT", body: "x" });
    expect((await readdir(join(root.path, "Tasks"))).filter((n) => n.includes("gks"))).toEqual([]);
  });

  it("overwrites with a matching If-Match and changes the ETag", async () => {
    const a = app();
    const etag = (await a.request("/api/file?path=digits.txt")).headers.get("ETag")!;
    const res = await a.request("/api/file?path=digits.txt", {
      method: "PUT",
      body: "abc",
      headers: { "If-Match": etag },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { etag: string };
    expect(body.etag).not.toBe(etag);
    expect(await readFile(join(root.path, "digits.txt"), "utf8")).toBe("abc");
  });

  it("returns 412 with the current ETag on a stale If-Match, without writing", async () => {
    const a = app();
    const current = (await a.request("/api/file?path=digits.txt")).headers.get("ETag")!;
    const res = await a.request("/api/file?path=digits.txt", {
      method: "PUT",
      body: "nope",
      headers: { "If-Match": '"1-1"' },
    });
    expect(res.status).toBe(412);
    expect(await res.json()).toEqual({ error: "conflict", etag: current });
    expect(await readFile(join(root.path, "digits.txt"), "utf8")).toBe("0123456789");
  });

  it("returns 412 for If-Match on a missing file", async () => {
    const res = await app().request("/api/file?path=missing.md", {
      method: "PUT",
      body: "x",
      headers: { "If-Match": '"1-1"' },
    });
    expect(res.status).toBe(412);
    expect(await res.json()).toEqual({ error: "conflict", etag: null });
  });

  it("supports create-only with If-None-Match: *", async () => {
    const a = app();
    const created = await a.request("/api/file?path=fresh.md", {
      method: "PUT",
      body: "1",
      headers: { "If-None-Match": "*" },
    });
    expect(created.status).toBe(200);
    const again = await a.request("/api/file?path=fresh.md", {
      method: "PUT",
      body: "2",
      headers: { "If-None-Match": "*" },
    });
    expect(again.status).toBe(412);
    expect(await readFile(join(root.path, "fresh.md"), "utf8")).toBe("1");
  });

  it("refuses to write over a directory or under a file", async () => {
    expect((await app().request("/api/file?path=Tasks", { method: "PUT", body: "x" })).status).toBe(400);
    expect((await app().request(`/api/file?path=${q("digits.txt/x.md")}`, { method: "PUT", body: "x" })).status).toBe(
      409,
    );
  });

  it("rejects bodies over the size limit", async () => {
    const small = createApp({ root: root.path, allowedLogins: [] }, { maxUploadBytes: 4 });
    const res = await small.request("/api/file?path=big.bin", { method: "PUT", body: "12345" });
    expect(res.status).toBe(413);
    await expect(stat(join(root.path, "big.bin"))).rejects.toThrow();
  });
});

describe("DELETE /api/file", () => {
  it("deletes a file with 204", async () => {
    const res = await app().request("/api/file?path=digits.txt", { method: "DELETE" });
    expect(res.status).toBe(204);
    await expect(stat(join(root.path, "digits.txt"))).rejects.toThrow();
  });

  it("honours If-Match", async () => {
    const a = app();
    const stale = await a.request("/api/file?path=digits.txt", { method: "DELETE", headers: { "If-Match": '"1-1"' } });
    expect(stale.status).toBe(412);
    const etag = (await a.request("/api/file?path=digits.txt")).headers.get("ETag")!;
    const ok = await a.request("/api/file?path=digits.txt", { method: "DELETE", headers: { "If-Match": etag } });
    expect(ok.status).toBe(204);
  });

  it("404s missing files and never deletes directories", async () => {
    expect((await app().request("/api/file?path=missing.md", { method: "DELETE" })).status).toBe(404);
    expect((await app().request("/api/file?path=Tasks", { method: "DELETE" })).status).toBe(400);
    expect((await stat(join(root.path, "Tasks"))).isDirectory()).toBe(true);
  });
});

describe("path security", () => {
  it.each([
    "../secret.txt",
    "Tasks/../../secret.txt",
    "/etc/passwd",
    "Tasks\\README.md",
    "Tasks/README.md\0",
    "Tasks//README.md",
    "./digits.txt",
  ])("400s %j on every route", async (path) => {
    const a = app();
    expect((await a.request(`/api/file?path=${q(path)}`)).status).toBe(400);
    expect((await a.request(`/api/list?path=${q(path)}`)).status).toBe(400);
    expect((await a.request(`/api/file?path=${q(path)}`, { method: "PUT", body: "x" })).status).toBe(400);
    expect((await a.request(`/api/file?path=${q(path)}`, { method: "DELETE" })).status).toBe(400);
  });

  it.each([".env", ".git/config", ".git", "Tasks/.hidden.md", "node_modules/x/index.js"])(
    "403s hidden path %j for read, list, write and delete",
    async (path) => {
      const a = app();
      expect((await a.request(`/api/file?path=${q(path)}`)).status).toBe(403);
      expect((await a.request(`/api/list?path=${q(path)}`)).status).toBe(403);
      expect((await a.request(`/api/file?path=${q(path)}`, { method: "PUT", body: "x" })).status).toBe(403);
      expect((await a.request(`/api/file?path=${q(path)}`, { method: "DELETE" })).status).toBe(403);
    },
  );

  it("403s reads through a symlink that escapes the root", async () => {
    await symlink(join(outside.path, "secret.txt"), join(root.path, "leak.txt"));
    await symlink(outside.path, join(root.path, "outdir"));
    const a = app();
    expect((await a.request("/api/file?path=leak.txt")).status).toBe(403);
    expect((await a.request(`/api/file?path=${q("outdir/secret.txt")}`)).status).toBe(403);
    expect((await a.request("/api/list?path=outdir")).status).toBe(403);
  });

  it("403s a symlink inside the root that targets a hidden path", async () => {
    await symlink(join(root.path, ".env"), join(root.path, "env.txt"));
    expect((await app().request("/api/file?path=env.txt")).status).toBe(403);
  });

  it("403s writes and deletes through an escaping symlink, leaving the outside untouched", async () => {
    await symlink(outside.path, join(root.path, "outdir"));
    await symlink(join(outside.path, "secret.txt"), join(root.path, "leak.txt"));
    const a = app();
    expect((await a.request(`/api/file?path=${q("outdir/new.txt")}`, { method: "PUT", body: "x" })).status).toBe(403);
    expect((await a.request(`/api/file?path=${q("outdir/sub/new.txt")}`, { method: "PUT", body: "x" })).status).toBe(
      403,
    );
    expect((await a.request("/api/file?path=leak.txt", { method: "PUT", body: "x" })).status).toBe(403);
    expect((await a.request("/api/file?path=leak.txt", { method: "DELETE" })).status).toBe(403);
    expect(await readdir(outside.path)).toEqual(["secret.txt"]);
    expect(await readFile(join(outside.path, "secret.txt"), "utf8")).toBe("outside");
  });
});

describe("GET /api/events", () => {
  it("emits a change event after a file write and cleans up on disconnect", async () => {
    const watcher = new SharedWatcher(root.path, 50);
    const a = createApp({ root: root.path, allowedLogins: [] }, { watcher });
    const res = await a.request("/api/events");
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("text/event-stream; charset=utf-8");
    expect(watcher.subscriberCount).toBe(1);

    const reader = res.body!.getReader();
    const decoder = new TextDecoder();
    let received = decoder.decode((await reader.read()).value);
    expect(received).toContain(": connected");

    // Give fs.watch a moment to arm before writing.
    await new Promise((resolve) => setTimeout(resolve, 100));
    const put = await a.request(`/api/file?path=${q("Tasks/new.md")}`, { method: "PUT", body: "x" });
    expect(put.status).toBe(200);

    const deadline = Date.now() + 5000;
    while (!received.includes("event: change") && Date.now() < deadline) {
      const { value, done } = await reader.read();
      if (done) {
        break;
      }
      received += decoder.decode(value);
    }
    const match = /event: change\ndata: (.+)\n\n/.exec(received);
    expect(match).not.toBeNull();
    const data = JSON.parse(match![1]!) as { paths: string[] };
    expect(data.paths).toContain("Tasks/new.md");
    expect(data.paths.some((p) => p.split("/").some((s) => s.startsWith(".")))).toBe(false);

    await reader.cancel();
    expect(watcher.subscriberCount).toBe(0);
    expect(watcher.isWatching).toBe(false);
  });

  it("shares one watcher across clients", async () => {
    const watcher = new SharedWatcher(root.path, 50);
    const a = createApp({ root: root.path, allowedLogins: [] }, { watcher });
    const first = await a.request("/api/events");
    const second = await a.request("/api/events");
    expect(watcher.subscriberCount).toBe(2);
    await first.body!.cancel();
    expect(watcher.isWatching).toBe(true);
    await second.body!.cancel();
    expect(watcher.isWatching).toBe(false);
  });

  it("sends periodic pings", async () => {
    const a = createApp({ root: root.path, allowedLogins: [] }, { pingIntervalMs: 30 });
    const res = await a.request("/api/events");
    const reader = res.body!.getReader();
    const decoder = new TextDecoder();
    let received = "";
    while (!received.includes(": ping")) {
      received += decoder.decode((await reader.read()).value);
    }
    expect(received).toContain(": ping");
    await reader.cancel();
  });
});
