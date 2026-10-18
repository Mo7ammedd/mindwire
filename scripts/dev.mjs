#!/usr/bin/env node
// Run the account portal by default. Agent runtime and website are explicit independent targets.
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const daemonDir = resolve(root, "packages/daemon");

const targets = process.argv.slice(2).filter(Boolean);
if (targets.length === 0) targets.push("console");
const available = new Set(["daemon", "console", "web"]);
if (targets.some((target) => !available.has(target))) {
  console.error("Usage: bun dev [daemon] [console] [web]");
  process.exit(1);
}

const addr = process.env.ADDR || "127.0.0.1:8790";
const daemonUrl = `http://${addr.replace(/^0\.0\.0\.0/, "127.0.0.1")}`;
// Reuse the private local daemon token between development restarts.
function devRuntimeToken(repoRoot) {
  const configured = process.env.MINDWIRE_RUNTIME_TOKEN || process.env.DAEMON_TOKEN;
  if (configured) return configured;
  const tokenFile = join(repoRoot, ".mindwire-dev-token");
  if (existsSync(tokenFile)) return readFileSync(tokenFile, "utf8").trim();
  const token = randomBytes(32).toString("hex");
  writeFileSync(tokenFile, `${token}\n`, { mode: 0o600 });
  return token;
}
const runtimeToken = targets.includes("daemon") ? devRuntimeToken(root) : undefined;

const procs = [];
let shuttingDown = false;

// Children run in their own process groups (detached) so a single kill(-pid) tears down the whole tree —
// notably `go run`, which forks a compiled binary that would otherwise orphan on Ctrl+C.
function run(name, cmd, args, env) {
  const p = spawn(cmd, args, { stdio: "inherit", cwd: env?.cwd ?? root, detached: true, env: env?.env ?? process.env });
  p.on("error", (e) => {
    console.error(`[dev] failed to start ${name}: ${e.code === "ENOENT" ? `'${cmd}' not found on PATH` : e.message}`);
    stopAll(1);
  });
  p.on("exit", (code, signal) => {
    if (shuttingDown) return;
    console.log(`\n[dev] ${name} exited (${signal || code}); stopping the rest…`);
    stopAll(code ?? 0);
  });
  procs.push({ name, p });
}

function stopAll(code = 0) {
  if (shuttingDown) return;
  shuttingDown = true;
  for (const { p } of procs) {
    try { process.kill(-p.pid, "SIGTERM"); } catch { try { p.kill("SIGTERM"); } catch {} }
  }
  // Give children a moment to exit cleanly, then leave.
  setTimeout(() => process.exit(code), 400);
}

for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => stopAll(0));

if (targets.includes("daemon")) {
  console.log(`[dev] daemon → ${daemonUrl}   (DEV_CORS on; agent fallback: ${process.env.AGENT_TYPE || "opencode"})`);
  run("daemon", "go", ["run", "./cmd/daemon"], {
    cwd: daemonDir,
    env: { ...process.env, DEV_CORS: "1", ADDR: addr, AGENT_TYPE: process.env.AGENT_TYPE || "opencode", DAEMON_TOKEN: runtimeToken },
  });
}
if (targets.includes("console")) {
  console.log("[dev] account portal → http://127.0.0.1:5174");
  run("console", "bun", ["--filter=@mindwire/console", "run", "dev"], { cwd: root, env: process.env });
}
if (targets.includes("web")) {
  console.log(`[dev] docs site → http://localhost:3000`);
  run("web", "bun", ["--filter=@mindwire/web", "run", "dev"], { cwd: root, env: process.env });
}
