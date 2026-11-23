import { describe, expect, it } from "vitest";
import { dnsSdArgs, tailnetUrlFromStatus, txtRecord } from "../src/announce.js";
import { loadConfig } from "../src/config.js";
import { contentTypeFor } from "../src/mime.js";
import { parseRange } from "../src/range.js";

describe("loadConfig", () => {
  it("applies defaults and never binds to all interfaces by default", () => {
    expect(loadConfig({ GKS_ROOT: "/tmp/x" })).toEqual({
      root: "/tmp/x",
      port: 4417,
      host: "127.0.0.1",
      allowedLogins: [],
      announce: true,
    });
  });

  it("parses port, host and the login allowlist", () => {
    const config = loadConfig({
      GKS_ROOT: "/tmp/x",
      GKS_PORT: "5000",
      GKS_HOST: "::1",
      GKS_ALLOWED_LOGINS: " a@x.com, b@y.com ,,",
    });
    expect(config).toMatchObject({ port: 5000, host: "::1", allowedLogins: ["a@x.com", "b@y.com"] });
  });

  it("rejects missing or relative roots and bad ports", () => {
    expect(() => loadConfig({})).toThrow(/GKS_ROOT/);
    expect(() => loadConfig({ GKS_ROOT: "relative" })).toThrow(/absolute/);
    expect(() => loadConfig({ GKS_ROOT: "/tmp", GKS_PORT: "99999" })).toThrow(/GKS_PORT/);
  });
});

describe("contentTypeFor", () => {
  it.each([
    ["a.PNG", "image/png"],
    ["a.jpeg", "image/jpeg"],
    ["a.md", "text/markdown; charset=utf-8"],
    ["a.usdz", "model/vnd.usdz+zip"],
    ["a.glb", "model/gltf-binary"],
    ["a.m4a", "audio/mp4"],
    ["a.mov", "video/quicktime"],
    ["a.unknown", "application/octet-stream"],
    ["Makefile", "application/octet-stream"],
  ])("%s → %s", (name, type) => {
    expect(contentTypeFor(name)).toBe(type);
  });
});

describe("parseRange", () => {
  it("handles full, partial and unsatisfiable ranges", () => {
    expect(parseRange(undefined, 10)).toEqual({ kind: "full" });
    expect(parseRange("bytes=0-0", 10)).toEqual({ kind: "partial", range: { start: 0, end: 0 } });
    expect(parseRange("bytes=-20", 10)).toEqual({ kind: "partial", range: { start: 0, end: 9 } });
    expect(parseRange("bytes=-0", 10)).toEqual({ kind: "unsatisfiable" });
    expect(parseRange("bytes=0-", 0)).toEqual({ kind: "unsatisfiable" });
    expect(parseRange("bytes=0-1,3-4", 10)).toEqual({ kind: "full" });
    expect(parseRange("items=0-1", 10)).toEqual({ kind: "full" });
  });
});

describe("announce", () => {
  it("reads the Bonjour options from env", () => {
    const config = loadConfig({ GKS_ROOT: "/tmp/x", GKS_ANNOUNCE: "0", GKS_PUBLIC_URL: "https://mac.tail.ts.net/", GKS_NAME: "Studio" });
    expect(config).toMatchObject({ announce: false, publicUrl: "https://mac.tail.ts.net", name: "Studio" });
    expect(() => loadConfig({ GKS_ROOT: "/tmp/x", GKS_PUBLIC_URL: "mac.tail.ts.net" })).toThrow(/GKS_PUBLIC_URL/);
  });

  it("puts the reachable address in the TXT record, and leaves it out when there is none", () => {
    expect(txtRecord({ root: "Projects", url: "https://mac.tail.ts.net" })).toEqual(["v=1", "root=Projects", "url=https://mac.tail.ts.net"]);
    expect(txtRecord({ root: "Projects" })).toEqual(["v=1", "root=Projects"]);
    expect(dnsSdArgs({ name: "Projects on Mac", root: "Projects", port: 4417 }, "https://m")).toEqual([
      "-R", "Projects on Mac", "_gitkanban._tcp", "local", "4417", "v=1", "root=Projects", "url=https://m",
    ]);
  });

  it("derives the Tailscale HTTPS address only while Tailscale runs", () => {
    const running = JSON.stringify({ BackendState: "Running", Self: { DNSName: "mac.tail60.ts.net." } });
    expect(tailnetUrlFromStatus(running)).toBe("https://mac.tail60.ts.net");
    expect(tailnetUrlFromStatus(JSON.stringify({ BackendState: "Stopped", Self: { DNSName: "mac.ts.net." } }))).toBeUndefined();
    expect(tailnetUrlFromStatus("not json")).toBeUndefined();
  });
});
