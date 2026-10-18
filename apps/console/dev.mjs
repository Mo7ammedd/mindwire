#!/usr/bin/env node
// Hosted account portal: Hono API + Vite, without building or starting an agent runtime.
import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const root = resolve(dirname(fileURLToPath(import.meta.url)));
const serverPort = process.env.PORT || "8787";
const procs = [];
let shuttingDown = false;

function run(name, cmd, args, env) {
  const p = spawn(cmd, args, { stdio: "inherit", cwd: root, detached: true, env: { ...process.env, ...env } });
  p.on("error", (e) => {
    console.error(`[console] failed to start ${name}: ${e.code === "ENOENT" ? `'${cmd}' not found on PATH` : e.message}`);
    stopAll(1);
  });
  p.on("exit", (code, signal) => {
    if (shuttingDown) return;
    console.log(`\n[console] ${name} exited (${signal || code}); stopping the rest…`);
    stopAll(code ?? 0);
  });
  procs.push(p);
  return p;
}

function stopAll(code = 0) {
  if (shuttingDown) return;
  shuttingDown = true;
  for (const p of procs) {
    try { process.kill(-p.pid, "SIGTERM"); } catch { try { p.kill("SIGTERM"); } catch {} }
  }
  setTimeout(() => process.exit(code), 400);
}
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => stopAll(0));

console.log(`[console] account API → http://127.0.0.1:${serverPort}`);
run("server", "bunx", ["tsx", "watch", "server/index.ts"], {
  PORT: serverPort,
  BASE_URL: process.env.BASE_URL || `http://127.0.0.1:${serverPort}`,
});

// Do not let the browser boot against a dead proxy. Vite otherwise serves immediately and its initial
// session/fleet requests fail with ECONNREFUSED while tsx is still compiling the API server; those
// loaders have no reason to retry a server that was simply not ready yet.
async function waitForApi() {
  const origin = `http://127.0.0.1:${serverPort}`;
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${origin}/api/ping`);
      if (response.ok) return;
    } catch {
      // tsx has not bound the port yet.
    }
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
  throw new Error(`Console API did not become ready at ${origin} within 15 seconds.`);
}

try {
  await waitForApi();
  console.log(`[console] app    → http://127.0.0.1:5174   ← open this`);
  run("client", "bunx", ["vite"], { SERVER_ORIGIN: `http://127.0.0.1:${serverPort}` });
} catch (error) {
  console.error(`[console] ${error instanceof Error ? error.message : String(error)}`);
  stopAll(1);
}
