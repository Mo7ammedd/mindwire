import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";
import { createHash, randomBytes } from "node:crypto";
import { Pool } from "pg";

const require = createRequire(import.meta.url);
let child: ChildProcess, directory: string, url: string, rpcID = 0;
let identityStatus = 200;
const postgresURL = process.env.PUSH_TEST_POSTGRES_URL;
let cleanupDatabase: (() => Promise<void>) | undefined;
const identity = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch(request) {
  if (identityStatus !== 200) return Response.json({}, { status: identityStatus });
  const token = request.headers.get("Authorization");
  const id = token === "Bearer account-a" ? 1 : token === "Bearer account-b" ? 2 : null;
  return Response.json({ authenticated: !!id, user: { id } });
} });

async function control<T = unknown>(action: string, value?: unknown): Promise<T> {
  const id = ++rpcID;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("Fixture timed out")), 5000);
    const listener = (message: any) => {
      if (message.id !== id) return;
      clearTimeout(timer); child.off("message", listener);
      if (message.error) reject(new Error(message.error)); else resolve(message.value);
    };
    child.on("message", listener);
    child.send?.({ id, action, value });
  });
}
async function request(path: string, method = "GET", body?: object, credential = "account-a") {
  const response = await fetch(url + "/api/notifications" + path, { method,
    headers: { Authorization: `Bearer ${credential}`, "Content-Type": "application/json" },
    ...(body ? { body: JSON.stringify(body) } : {}) });
  return { status: response.status, data: await response.json() as any };
}
async function register(device = "phone", token = "real-device-token", credential = "account-a") {
  return request("/devices", "POST", { device_id: device, fcm_token: token, platform: "ios" }, credential);
}
async function mint(input: object = {}, credential = "account-a") {
  const response = await request("/tokens", "POST", { tag: "workspace-phone", metadata: { channel: "workspace" }, ...input }, credential);
  expect(response.status).toBe(201);
  return response.data.token as { id: number; token: string; token_prefix: string };
}

beforeAll(async () => {
  directory = await mkdtemp(join(tmpdir(), "mindwire-push-test-"));
  let databaseURL = "";
  if (postgresURL) {
    const admin = new Pool({ connectionString: postgresURL });
    const name = "mindwire_push_test_" + randomBytes(6).toString("hex");
    await admin.query(`CREATE DATABASE ${name}`);
    const target = new URL(postgresURL); target.pathname = "/" + name; databaseURL = target.href;
    cleanupDatabase = async () => { try { await admin.query(`DROP DATABASE ${name} WITH (FORCE)`); } finally { await admin.end(); } };
  }
  child = spawn("node", ["--import", require.resolve("tsx"), new URL("./fixtures/push-server.ts", import.meta.url).pathname], {
    stdio: ["ignore", "pipe", "pipe", "ipc"], env: { ...process.env,
      NODE_ENV: "test", CONSOLE_MODE: "cloud", BASE_URL: "http://127.0.0.1:8787", DATABASE_URL: databaseURL, POSTGRES_PASSWORD: "",
      AUTH_DB_PATH: join(directory, "auth.db"), AUTH_SECRET: randomBytes(48).toString("base64url"),
      SECRETS_ENCRYPTION_KEY: randomBytes(32).toString("base64url"),
      PUSH_IDENTITY_PROVIDER_URL: `http://127.0.0.1:${identity.port}`, SEED_DEFAULT_DAEMON: "false",
    },
  });
  url = await new Promise<string>((resolve, reject) => {
    let log = "";
    child.stderr?.on("data", chunk => { log = (log + chunk).slice(-4000); });
    child.on("message", (message: any) => { if (message.ready) resolve(message.ready); });
    child.once("exit", code => reject(new Error(`Fixture exited ${code}: ${log}`)));
    setTimeout(() => reject(new Error(`Startup timeout: ${log}`)), 15000).unref();
  });
}, 20000);
beforeEach(async () => { identityStatus = 200; await control("clear"); });
afterAll(async () => {
  child?.kill("SIGTERM"); identity.stop(true);
  await cleanupDatabase?.();
  if (directory) await rm(directory, { recursive: true, force: true });
});

test("real API and database isolate devices, encrypt tokens and keep management off daemon credentials", async () => {
  const registered = await register();
  expect(registered.status).toBe(201);
  expect(JSON.stringify(registered.data)).not.toContain("real-device-token");
  expect(JSON.stringify(await control("stored"))).not.toContain("real-device-token");
  expect((await request("/devices", "GET", undefined, "account-b")).data.devices).toEqual([]);
  expect((await request("/devices/status?device_id=phone", "GET", undefined, "account-b")).data.registered).toBe(false);
  await request(`/devices/${registered.data.device.id}`, "DELETE", undefined, "account-b");
  expect((await request("/devices/status?device_id=phone")).data.registered).toBe(true);
  const token = await mint();
  expect((await request("/devices", "GET", undefined, token.token)).status).toBe(401);
  expect((await fetch(url + "/api/private")).status).toBe(401);
  expect((await fetch(url + "/api/notifications-other")).status).toBe(401);
});

test("native identity is verified and outages do not become invalid login or anonymous access", async () => {
  expect((await register("phone", "token", "anonymous-session")).status).toBe(401);
  expect((await register("phone", "token", "namespace-credential")).status).toBe(401);
  identityStatus = 503;
  expect((await register()).status).toBe(503);
  identityStatus = 200;
  expect((await register()).status).toBe(201);
});

test("browser push management requires a trusted origin and never changes another identity", async () => {
  const cookie = await control<string>("newAccount");
  expect(cookie).toBeTruthy();
  const post = (origin?: string) => fetch(url + "/api/notifications/devices", { method: "POST",
    headers: { Cookie: cookie, "Content-Type": "application/json", ...(origin ? { Origin: origin } : {}) },
    body: JSON.stringify({ device_id: "browser", fcm_token: "browser-token", platform: "web" }) });
  expect((await post()).status).toBe(403);
  expect((await post("https://attacker.example")).status).toBe(403);
  expect((await post("http://127.0.0.1:8787")).status).toBe(201);
  expect((await request("/devices")).data.devices).toEqual([]);
});

test("tag rotation stays one row under concurrent calls and old, expired or revoked secrets cannot send", async () => {
  await register();
  const minted = await Promise.all(Array.from({ length: 8 }, () => mint()));
  expect(new Set(minted.map(value => value.id)).size).toBe(1);
  expect((await request("/tokens")).data.tokens).toHaveLength(1);
  const outcomes = await Promise.all(minted.map(value => request("/send", "POST", { title: "Done" }, value.token)));
  expect(outcomes.filter(value => value.status === 200)).toHaveLength(1);
  const live = minted[outcomes.findIndex(value => value.status === 200)];
  await request(`/tokens/${live.id}/revoke`, "POST");
  expect((await request("/send", "POST", { title: "Done" }, live.token)).status).toBe(401);
  const expired = await mint();
  await control("expire", expired.id);
  expect((await request("/send", "POST", { title: "Done" }, expired.token)).status).toBe(401);
});

test("one daemon request reaches only its owner's pinned device with existing deep-link metadata", async () => {
  await register("phone-a", "token-a");
  await register("phone-b", "token-b");
  await register("stranger", "token-stranger", "account-b");
  const token = await mint({ device_id: "phone-a" });
  const result = await request("/send", "POST", { title: "Finished", body: "Ready", data: { chat_id: "chat", mutable: true, workspace_id: "forged" } }, token.token);
  expect(result.data).toMatchObject({ delivered: 1, failed: 0, devices: 1 });
  const sent = await control<any[]>("sent");
  expect(sent).toHaveLength(1);
  expect(sent[0].tokens).toEqual(["token-a"]);
  expect(sent[0].message.data).toMatchObject({ channel: "workspace", chat_id: "chat", mutable: "true" });
  expect(JSON.stringify((await request("/tokens")).data)).not.toContain(token.token);
});

test("late Firebase invalidation cannot revoke a newly rotated device token", async () => {
  await register("rotating-device", "dead-token");
  await control("rotate");
  const token = await mint();
  expect((await request("/send", "POST", { title: "Done" }, token.token)).data.failed).toBe(1);
  expect((await request("/devices/status?device_id=rotating-device")).data.status).toBe("active");
  expect((await request("/send", "POST", { title: "Done" }, token.token)).data.delivered).toBe(1);
});

test("invalid payloads and unknown routes fail without silently claiming delivery", async () => {
  expect((await register("phone", "invalid-device")).status).toBe(400);
  expect((await request("/devices/1junk", "DELETE")).status).toBe(400);
  const token = await mint();
  expect((await request("/send", "POST", { title: "Huge", data: { text: "x".repeat(5000) } }, token.token)).status).toBe(413);
  expect((await request("/send", "POST", { data: [] }, token.token)).status).toBe(400);
  expect((await request("/unknown")).status).toBe(404);
  expect(await control("sent")).toEqual([]);
});

test.skipIf(!postgresURL)("Cloud import preserves existing ids, hashes, routing and revocation in one transaction", async () => {
  const legacySecret = "onp_" + "f".repeat(64), created = "2026-09-01T00:00:00.000Z";
  const snapshot = { format: "mindwire-push-export-v1", devices: [{ id: 70, user_id: "1", device_id: "phone", fcm_token: "legacy-device-token", platform: "ios", status: "active", created_at: created, last_seen_at: created }],
    tokens: [{ id: 90, user_id: "1", workspace_id: "workspace", tag: "old-tag", token_hash: createHash("sha256").update(legacySecret).digest("hex"), token_prefix: legacySecret.slice(0, 12), status: "active", metadata: { device_id: 70, channel: "workspace" }, created_at: created }] };
  expect(await control("import", { snapshot, apply: false })).toMatchObject({ devices: 1, tokens: 1, applied: false });
  expect((await request("/devices")).data.devices).toEqual([]);
  const malformed = { ...snapshot, tokens: [...snapshot.tokens, snapshot.tokens[0]] };
  await expect(control("import", { snapshot: malformed, apply: true })).rejects.toThrow();
  expect((await request("/devices")).data.devices).toEqual([]);
  expect(await control("import", { snapshot, apply: true })).toMatchObject({ devices: 1, tokens: 1, applied: true });
  expect((await request("/devices/status?device_id=phone")).data.id).toBe(70);
  expect((await request("/send", "POST", { title: "Old daemon still works" }, legacySecret)).data.delivered).toBe(1);
  await expect(control("import", { snapshot, apply: true })).rejects.toThrow("not empty");
  expect((await request("/devices")).data.devices).toHaveLength(1);
  const fresh = await register("new-phone", "new-token");
  expect(fresh.data.device.id).toBeGreaterThan(70);
  const token = await mint();
  expect(token.id).toBeGreaterThan(90);
});
