#!/usr/bin/env node
// agent-guard: turns agent corrections into checks (no dependencies).
//
//   node tools/agent-guard/agent-guard.mjs            check against the baseline
//   node tools/agent-guard/agent-guard.mjs --update   rewrite the baseline (after you removed violations)
//   node tools/agent-guard/agent-guard.mjs --list ID  print every current hit for one rule
//
// Rules live in agent-guard.config.json next to this file. Existing violations are
// recorded in agent-guard.baseline.json, so a rule can land today without a big
// cleanup: the count may go down, never up. A rule with no baseline entry allows 0.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: here }).toString().trim();
const configPath = join(here, "agent-guard.config.json");
const baselinePath = join(here, "agent-guard.baseline.json");
const config = JSON.parse(readFileSync(configPath, "utf8"));
const baseline = existsSync(baselinePath) ? JSON.parse(readFileSync(baselinePath, "utf8")) : {};
const args = process.argv.slice(2);
const update = args.includes("--update");
const listId = args.includes("--list") ? args[args.indexOf("--list") + 1] : null;

const files = execFileSync("git", ["ls-files", "-z"], { cwd: root, maxBuffer: 1 << 28 })
  .toString()
  .split("\0")
  .filter(Boolean);

const matchesScope = (file, rule) => {
  const inc = rule.include ?? [""];
  const exc = rule.exclude ?? [];
  const ext = rule.ext ?? [];
  if (!inc.some((p) => file.startsWith(p))) return false;
  if (exc.some((p) => (p.startsWith("*") ? file.includes(p.slice(1)) : file.startsWith(p)))) return false;
  if (ext.length && !ext.some((e) => file.endsWith(e))) return false;
  return true;
};

const cache = new Map();
const read = (file) => {
  if (!cache.has(file)) {
    let text = "";
    try {
      text = readFileSync(join(root, file), "utf8");
    } catch {}
    cache.set(file, text.includes("\0") ? "" : text);
  }
  return cache.get(file);
};

const counts = {};
const hits = {};
for (const rule of config.rules) {
  const re = new RegExp(rule.pattern, rule.flags ?? "");
  counts[rule.id] = 0;
  hits[rule.id] = [];
  for (const file of files) {
    if (!matchesScope(file, rule)) continue;
    const lines = read(file).split("\n");
    lines.forEach((line, i) => {
      if (re.test(line)) {
        counts[rule.id]++;
        hits[rule.id].push(`${file}:${i + 1}: ${line.trim().slice(0, 140)}`);
      }
    });
  }
}

if (listId) {
  console.log((hits[listId] ?? [`unknown rule ${listId}`]).join("\n"));
  process.exit(0);
}

if (update) {
  const next = Object.fromEntries(Object.entries(counts).filter(([, n]) => n > 0));
  writeFileSync(baselinePath, JSON.stringify(next, null, 2) + "\n");
  console.log(`agent-guard: baseline written to ${relative(root, baselinePath)}`);
  for (const [id, n] of Object.entries(next)) console.log(`  ${id}: ${n}`);
  process.exit(0);
}

let failed = 0;
for (const rule of config.rules) {
  const allowed = baseline[rule.id] ?? 0;
  const n = counts[rule.id];
  if (n > allowed) {
    failed++;
    console.error(`\n✗ ${rule.id}: ${n} hits, baseline allows ${allowed}`);
    console.error(`  Why: ${rule.why}`);
    console.error(`  Do instead: ${rule.fix}`);
    for (const h of hits[rule.id].slice(-Math.min(n - allowed + 5, 15))) console.error(`    ${h}`);
  } else if (n < allowed) {
    console.log(`↓ ${rule.id}: ${n} (baseline ${allowed}). Run with --update to lock in the improvement.`);
  }
}

if (failed) {
  console.error(
    `\nagent-guard: ${failed} rule(s) regressed. Fix the root cause; do not add a comment explaining the workaround.`
  );
  process.exit(1);
}
console.log(`agent-guard: ${config.rules.length} rules OK`);
