#!/usr/bin/env node
// Decision logs are one file per decision so parallel PRs never edit the same lines.
//   node scripts/decisions-index.mjs           print the index of every log (read time, nothing committed)
//   node scripts/decisions-index.mjs --check   validate every decision file (run by `npm run check`)
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const logs = [
  { dir: "apps/gitmail-macos/docs/decisions", prefix: "MAIL", digits: 3 },
  { dir: "apps/gitkanban-macos/docs/decisions", prefix: "TASKS", digits: 2 },
];
const statuses = new Set(["proposed", "accepted", "open", "superseded"]);

function parse(text) {
  const m = text.match(/^---\n([\s\S]*?)\n---\n/);
  if (!m) return null;
  const fields = {};
  for (const line of m[1].split("\n")) {
    const kv = line.match(/^([a-z_]+): (.*)$/);
    if (!kv) return null;
    fields[kv[1]] = kv[2].startsWith('"') ? JSON.parse(kv[2]) : kv[2];
  }
  return fields;
}

const sortKey = (id) => {
  const m = id.match(/^[A-Z]+-(\d+)(.*)$/);
  return [Number(m[1]), m[2]];
};

const problems = [];
const entries = [];
for (const log of logs) {
  const dir = join(root, log.dir);
  const idPattern = new RegExp(`^${log.prefix}-\\d{${log.digits},}[a-z]?$`);
  const seen = new Set();
  for (const file of readdirSync(dir).filter((f) => f.endsWith(".md")).sort()) {
    const where = `${log.dir}/${file}`;
    const text = readFileSync(join(dir, file), "utf8");
    const f = parse(text);
    if (!f) { problems.push(`${where}: missing or malformed front matter`); continue; }
    const id = file.slice(0, -3);
    if (!idPattern.test(id)) problems.push(`${where}: file name must look like ${log.prefix}-${"N".repeat(log.digits)}.md`);
    if (f.id !== id) problems.push(`${where}: id "${f.id}" does not match the file name`);
    if (seen.has(f.id)) problems.push(`${where}: duplicate id ${f.id}`);
    seen.add(f.id);
    for (const key of ["title", "date", "status"]) if (!f[key]) problems.push(`${where}: missing ${key}`);
    if (f.date && !/^\d{4}-\d{2}-\d{2}$/.test(f.date)) problems.push(`${where}: date must be YYYY-MM-DD`);
    if (f.status && !statuses.has(f.status)) problems.push(`${where}: status must be one of ${[...statuses].join(", ")}`);
    if (!new RegExp(`^# (${f.id}|§ \\d+)\\b`, "m").test(text)) problems.push(`${where}: no "# ${f.id}" or "# § N" heading`);
    entries.push({ log, id, f });
  }
}

if (process.argv.includes("--check")) {
  if (problems.length) {
    console.error(problems.join("\n"));
    process.exit(1);
  }
  console.log(`decisions: ${entries.length} files ok`);
} else {
  for (const log of logs) {
    console.log(`\n${log.dir}\n`);
    const list = entries.filter((e) => e.log === log).sort((a, b) => {
      const [an, as] = sortKey(a.id), [bn, bs] = sortKey(b.id);
      return an - bn || as.localeCompare(bs);
    });
    for (const { id, f } of list) console.log(`${id}  ${f.date}  ${f.status.padEnd(10)} ${f.title}`);
  }
}
