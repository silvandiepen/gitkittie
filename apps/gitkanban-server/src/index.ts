import { statSync } from "node:fs";
import { basename } from "node:path";
import { serve } from "@hono/node-server";
import { createApp } from "./app.js";
import { loadConfig } from "./config.js";
import { computerName, defaultServiceName, startAnnouncing, type Announcer } from "./announce.js";

function main(): void {
  const config = loadConfig(process.env);
  if (!statSync(config.root).isDirectory()) {
    throw new Error(`GKS_ROOT "${config.root}" is not a directory.`);
  }
  const app = createApp(config);
  let announcer: Announcer | undefined;
  const server = serve({ fetch: app.fetch, port: config.port, hostname: config.host }, (info) => {
    const auth = config.allowedLogins.length > 0 ? `logins: ${config.allowedLogins.join(", ")}` : "no login allowlist";
    console.log(`[gitkanban-server] serving ${config.root} on http://${info.address}:${info.port} (${auth})`);
    if (config.announce) {
      const root = basename(config.root);
      announcer = startAnnouncing(
        { name: config.name ?? defaultServiceName(root, computerName()), root, port: info.port, publicUrl: config.publicUrl },
        (message) => console.log(`[gitkanban-server] ${message}`),
      );
    }
  });

  const shutdown = (signal: string): void => {
    console.log(`[gitkanban-server] ${signal} received, shutting down`);
    announcer?.stop();
    server.close(() => process.exit(0));
    // SSE connections keep the server open; don't wait on them forever.
    setTimeout(() => process.exit(0), 2000).unref();
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}

try {
  main();
} catch (error) {
  console.error(`[gitkanban-server] ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}
