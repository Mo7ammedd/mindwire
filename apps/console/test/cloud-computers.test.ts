import { afterAll, beforeAll, expect, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";
import { Pool } from "pg";
import { randomBytes, createHmac } from "node:crypto";

const require = createRequire(import.meta.url);
let child: ChildProcess, directory: string, url: string;
const postgresURL = process.env.CLOUD_TEST_POSTGRES_URL;
let cleanupDatabase: (() => Promise<void>) | undefined;
let owner: { token: string; user: { id: string } }, stranger: typeof owner;
const namespaces = new Set<string>(), payments = new Map<string, any>(), computers = new Map<string, any>();
const canceled = new Set<string>();
const previousTokens = new Set(["fixture-previous-account-session"]);
let loseDeleteReply = false, redirectWorkspaceRead = false;
let paid = false, loseCheckoutReply = false, loseCreateReply = false, checkoutWrites = 0, creates = 0;
const issuedRuntimeTokens = new Map<string, string>();
const providerRequests: Array<{ path: string; namespace: string | null }> = [];
const fake = Bun.serve({ port: 0, hostname: "127.0.0.1", async fetch(request) {
  const u = new URL(request.url), path = u.pathname;
  const body = request.method === "GET" ? {} : await request.json().catch(() => ({})) as any;
  const bearer = request.headers.get("Authorization")?.replace(/^Bearer /, "") ?? "";
  if (path === "/auth/status") return Response.json(previousTokens.has(bearer) ? { authenticated: true, user: { id: 73 } } : { authenticated: false }, { status: previousTokens.has(bearer) ? 200 : 401 });
  if (path === "/auth/token" && previousTokens.has(bearer) && body.old_token === bearer) {
    const next = bearer + "_renewed"; previousTokens.add(next); previousTokens.delete(bearer);
    return Response.json({ success: true, token: next });
  }
  const master = request.headers.get("X-Client-ID") === "reseller" && request.headers.get("X-Client-Secret") === "private-secret";
  const namespace = request.headers.get("Authorization")?.replace(/^Bearer namespace:/, "") ?? null;
  providerRequests.push({ path, namespace });
  const ok = (value: object) => Response.json({ success: true, ...value });
  if (!master && !namespaces.has(namespace ?? "")) return Response.json({}, { status: 401 });
  if (path === "/disks" && request.method === "GET") {
    const computer = [...computers.values()].find(c => c.namespace === namespace);
    if (!computer) return Response.json({}, { status: 404 });
    return ok({ disks: [{ id: `disk_${computer.id}`, namespace }] });
  }
  if (path === "/workspace/images") return ok({ images: [{ id: "linux", image: "ubuntu:24.04", base_os: { family: "linux" } }, { id: "mac", image: "macos:15", base_os: { family: "macos" }, minimum_resources: { memory_mb: 11264 } }, { id: "mac-xcode", image: "macos:15", preset: "macos-xcode", vm_defaults: { enable_kvm: true }, base_os: { family: "macos" }, minimum_resources: { cpus: 8, memory_mb: 24576 } }] });
  if (path === "/billing/capacity/catalog") return ok({ tariffId: "test-tariff", tariff: { monthly: { minimumCents: 500, vcpuCents: 600, memoryGiBCents: 100, diskGiBCents: 5 } }, paymentSources: { monthly: ["stripe"] } });
  if (path === "/namespaces/ensure" && master) { namespaces.add(body.slug); return ok({ data: { slug: body.slug } }); }
  if (path === "/tokens" && master) return ok({ token: `namespace:${body.namespace}`, scope: "namespace", expiresAt: new Date(Date.now() + 300000).toISOString() });
  if (path === "/billing/checkout" && master) {
    let checkout = payments.get(body.idempotencyKey);
    if (!checkout) { checkout = { id: "cs_" + payments.size, request: body }; payments.set(body.idempotencyKey, checkout); checkoutWrites++; }
    else expect(checkout.request).toEqual(body);
    if (loseCheckoutReply) { loseCheckoutReply = false; return Response.json({ error: "lost reply" }, { status: 503 }); }
    return ok({ url: `https://checkout.stripe.com/c/pay/${checkout.id}`, checkoutId: checkout.id });
  }
  if (path === "/billing/entitlement" && master) {
    const ns = u.searchParams.get("namespace")!;
    const checkout = [...payments.values()].find(p => p.request.namespace === ns);
    return ok({ namespace: ns, status: paid ? "active" : "canceled", billingMode: "monthly", computeCovered: paid,
      periodEnd: new Date(Date.now() + 86400000).toISOString(), capacity: { capacity: checkout?.request.offer.capacity } });
  }
  if (path === "/billing/subscription" && master) {
    const ns = u.searchParams.get("namespace")!;
    const checkout = [...payments.values()].find(p => p.request.namespace === ns);
    return ok({ namespace: ns, subscription: paid ? { status: "active", periodEnd: new Date(Date.now() + 86400000).toISOString(), cancelAtPeriodEnd: canceled.has(ns), offer: checkout?.request.offer } : null });
  }
  if (/^\/billing\/subscription\/(cancel|resume)$/.test(path) && master) {
    if (path.endsWith("/cancel")) canceled.add(body.namespace); else canceled.delete(body.namespace);
    return ok({ namespace: body.namespace, subscription: { status: "active", periodEnd: new Date(Date.now() + 86400000).toISOString(), cancelAtPeriodEnd: canceled.has(body.namespace) } });
  }
  if (/^\/billing\/checkout\/cs_\d+\/cancel$/.test(path) && master) {
    const checkout = [...payments.values()].find(p => p.id === path.split("/")[3]);
    return ok({ namespace: body.namespace, checkout: { id: checkout.id, status: paid ? "complete" : "expired", paymentStatus: paid ? "paid" : "unpaid" } });
  }
  if (path === "/workspace" && request.method === "POST" && namespace === body.namespace) {
    let computer = computers.get(body.idempotency_key);
    if (!computer) { computer = { id: "vm_" + creates, namespace, image: body.image, preset: body.preset, enableKvm: body.config?.enable_kvm, cpus: body.config?.cpus, memoryMb: body.config?.memory_mb, diskMb: body.config?.disk_size_mb, ready: true, status: "running" }; computers.set(body.idempotency_key, computer); creates++; }
    if (loseCreateReply) { loseCreateReply = false; return Response.json({}, { status: 503 }); }
    return ok({ workspace: computer });
  }
  const grantRequest = /^\/workspace\/(vm_\d+)\/runtime-api-access\/token$/.exec(path);
  if (grantRequest) {
    const computer = [...computers.values()].find(c => c.id === grantRequest[1]);
    if (computer?.namespace !== namespace) return Response.json({}, { status: 404 });
    const payload = Buffer.from(JSON.stringify({ workspace_id: computer.id, exp: Math.floor(Date.now() / 1000) + 3600 })).toString("base64url");
    const token = "eyJhbGciOiJIUzI1NiJ9." + payload + ".signature";
    issuedRuntimeTokens.set(computer.id, token);
    return ok({ token, enabled: true });
  }
  if (/^\/workspace\/vm_\d+\/(?:stop|start|restart)$/.test(path) && request.method === "POST") return ok({});
  if (/^\/workspace\/vm_\d+$/.test(path)) {
    if (request.method === "GET" && redirectWorkspaceRead) {
      redirectWorkspaceRead = false;
      return new Response(null, { status: 302, headers: { Location: new URL("/unexpected", fake.url).href } });
    }
    const computer = [...computers.values()].find(c => c.id === path.split("/").pop());
    if (computer?.namespace === namespace) {
      if (request.method === "DELETE") {
        for (const [key, c] of computers) if (c.id === computer.id) computers.delete(key);
        if (loseDeleteReply) { loseDeleteReply = false; return Response.json({}, { status: 503 }); }
        return ok({});
      }
      if (request.method === "PUT") computer.name = body.name;
      return ok({ workspace: computer });
    }
  }
  return Response.json({ error: "not found" }, { status: 404 });
} });

async function api(path: string, method = "GET", body?: object, token = owner?.token) {
  const response = await fetch(url + path, { method, headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: body ? JSON.stringify(body) : undefined });
  const text = await response.text();
  const data = JSON.parse(text);
  return { status: response.status, data, headers: response.headers };
}
beforeAll(async () => {
  directory = await mkdtemp(join(tmpdir(), "mindwire-cloud-test-"));
  let databaseURL = "";
  if (postgresURL) {
    const admin = new Pool({ connectionString: postgresURL });
    const name = "mindwire_cloud_test_" + randomBytes(6).toString("hex");
    await admin.query(`CREATE DATABASE ${name}`);
    const target = new URL(postgresURL); target.pathname = "/" + name; databaseURL = target.href;
    cleanupDatabase = async () => { try { await admin.query(`DROP DATABASE ${name} WITH (FORCE)`); } finally { await admin.end(); } };
  }
  child = spawn("node", ["--import", require.resolve("tsx"), new URL("./fixtures/cloud-server.ts", import.meta.url).pathname], { stdio: ["ignore", "pipe", "pipe", "ipc"], env: { ...process.env,
    NODE_ENV: "test", CONSOLE_MODE: "cloud", BASE_URL: "http://127.0.0.1:8787", DATABASE_URL: databaseURL, POSTGRES_HOST: "", AUTH_DB_PATH: join(directory, "auth.db"),
    AUTH_SECRET: randomBytes(48).toString("base64url"), SECRETS_ENCRYPTION_KEY: randomBytes(32).toString("base64url"),
    PUSH_IDENTITY_PROVIDER_URL: fake.url.origin, OBLIEN_CLIENT_ID: "reseller", OBLIEN_CLIENT_SECRET: "private-secret", OBLIEN_BASE_URL: fake.url.origin, OBLIEN_WEBHOOK_SECRET: "fixture-webhook-secret", SEED_DEFAULT_DAEMON: "false",
  } });
  url = await new Promise<string>((resolve, reject) => {
    let log = ""; child.stderr?.on("data", chunk => log = (log + chunk).slice(-4000));
    child.on("message", (message: any) => { if (message.ready) resolve(message.ready); });
    child.once("exit", code => reject(new Error(`Fixture exited ${code}: ${log}`)));
    setTimeout(() => reject(new Error(`Fixture timeout: ${log}`)), 20000).unref();
  });
  owner = (await api("/api/account/sign-up/email", "POST", { email: "owner@example.test", password: "fixture-password-123456", name: "Owner" }, "")).data;
  stranger = (await api("/api/account/sign-up/email", "POST", { email: "stranger@example.test", password: "fixture-password-123456", name: "Stranger" }, "")).data;
  expect(owner.token).toBeTruthy(); expect(stranger.token).toBeTruthy();
}, 25000);
afterAll(async () => { child?.kill("SIGTERM"); fake.stop(true); await cleanupDatabase?.(); if (directory) await rm(directory, { recursive: true, force: true }); });

const purchase = () => ({ idempotencyKey: randomBytes(16).toString("hex"), name: "My computer", planId: "essential", imageId: "linux" });

test("Mindwire native session owns its account without provider auth", async () => {
  expect((await api("/api/cloud/account", "GET", undefined, "")).status).toBe(401);
  expect((await api("/api/cloud/account")).data.user.id).toBe(owner.user.id);
  expect((await api("/api/cloud/computers", "GET", undefined, "namespace:operator")).status).toBe(401);
});

test("monthly drafts isolate owners and enforce exact idempotent replay", async () => {
  const input = purchase();
  const [a, b] = await Promise.all([api("/api/cloud/computers", "POST", input), api("/api/cloud/computers", "POST", input)]);
  expect(a.status).toBe(201); expect(a.data.computer.id).toBe(b.data.computer.id);
  const id = a.data.computer.id;
  expect((await api(`/api/cloud/computers/${id}`, "GET", undefined, stranger.token)).status).toBe(404);
  expect((await api("/api/cloud/computers", "POST", { ...input, planId: "pro" })).status).toBe(409);
  expect((await api("/api/cloud/computers", "POST", { ...purchase(), imageId: "mac" })).status).toBe(400);
});

test("uncertain checkout retries reuse the saved request and never double charge", async () => {
  const created = await api("/api/cloud/computers", "POST", purchase()), id = created.data.computer.id;
  const before = checkoutWrites; loseCheckoutReply = true;
  expect((await api(`/api/cloud/computers/${id}/checkout`, "POST")).status).toBe(503);
  expect((await api(`/api/cloud/computers/${id}`)).data.computer.state).toBe("checkout_pending");
  const retry = await api(`/api/cloud/computers/${id}/checkout`, "POST");
  expect(retry.status).toBe(200); expect(retry.data.computer.state).toBe("payment_pending");
  expect(checkoutWrites - before).toBe(1);
  expect((await api(`/api/cloud/computers/${id}/checkout`, "POST", undefined, stranger.token)).status).toBe(404);
});

test("payment redirects cannot provision; authoritative paid capacity creates one owned VM", async () => {
  const id = (await api("/api/cloud/computers", "POST", purchase())).data.computer.id;
  await api(`/api/cloud/computers/${id}/checkout`, "POST");
  const before = creates;
  const pending = await api(`/api/cloud/computers/${id}/reconcile`, "POST", { paid: true, namespace: "operator" });
  expect(pending.status).toBe(200); expect(pending.data.computer.workspaceId).toBeNull(); expect(creates).toBe(before);
  paid = true;
  const done = await api(`/api/cloud/computers/${id}/reconcile`, "POST");
  expect(done.status).toBe(200); expect(done.data.computer.state).toBe("ready");
  await api(`/api/cloud/computers/${id}/reconcile`, "POST");
  expect(creates - before).toBe(1);
  const vm = done.data.computer.workspaceId;
  expect((await api(`/api/cloud/provider/workspace/${vm}`)).status).toBe(200);
  const calls = providerRequests.length;
  expect((await api(`/api/cloud/provider/workspace/${vm}`, "GET", undefined, stranger.token)).status).toBe(404);
  expect(providerRequests.length).toBe(calls);
  expect((await api("/api/cloud/provider/workspace", "POST", { image: "ubuntu:24.04" })).status).toBe(409);
});

test("management redirects cannot forward the Mindwire account session", async () => {
  const vm = [...computers.values()][0].id;
  redirectWorkspaceRead = true;
  const result = await api(`/api/cloud/provider/workspace/${vm}`);
  expect(result.status).toBe(502);
  expect(result.data.code).toBe("unexpected_cloud_redirect");
  expect(result.headers.get("Location")).toBeNull();
  expect(providerRequests.filter(r => r.path === "/unexpected")).toHaveLength(0);
  expect((await api(`/api/cloud/provider/workspace/${vm}`)).status).toBe(200);
});

test("unfinished purchases cannot break storage listings or request another owner's disks", async () => {
  const id = (await api("/api/cloud/computers", "POST", purchase())).data.computer.id;
  const draft = (await control("stored", id))[0];
  const before = providerRequests.length;
  const result = await api("/api/cloud/provider/disks");
  expect(result.status).toBe(200);
  expect(result.data.disks).toHaveLength(computers.size);
  expect(providerRequests.slice(before).filter(r => r.path === "/disks").map(r => r.namespace)).not.toContain(draft.namespace);
  const other = await api("/api/cloud/provider/disks", "GET", undefined, stranger.token);
  expect(other.status).toBe(200); expect(other.data.disks).toEqual([]);
  await api(`/api/cloud/computers/${id}/checkout/cancel`, "POST");
});

test("webhook accepts authentic scheduling only and cookie mutations reject foreign origins", async () => {
  const raw = JSON.stringify({ namespace: "not-a-mindwire-namespace" });
  const response = await fetch(url + "/api/cloud/webhook", { method: "POST", body: raw, headers: { "X-Webhook-Signature": createHmac("sha256", "fixture-webhook-secret").update(raw).digest("hex") } });
  expect(response.status).toBe(200);
  expect((await api("/api/cloud/webhook", "POST", {})).status).toBe(401);
  const login = await api("/api/account/sign-in/email", "POST", { email: "owner@example.test", password: "fixture-password-123456" }, "");
  const cookie = login.headers.get("set-cookie")!.split(";")[0];
  const attempted = await fetch(url + "/api/cloud/computers", { method: "POST", headers: { Cookie: cookie, Origin: "https://attacker.example", "Content-Type": "application/json" }, body: JSON.stringify(purchase()) });
  expect(attempted.status).toBe(403);
});

test("real device approval binds the client, is single-use and creates an independent native session", async () => {
  const started = await api("/api/account/device/code", "POST", { client_id: "mindwire-native" }, "");
  expect(started.status).toBe(200);
  const code = started.data;
  const poll = (client = "mindwire-native") => api("/api/account/device/token", "POST", { client_id: client, device_code: code.device_code, grant_type: "urn:ietf:params:oauth:grant-type:device_code" }, "");
  expect((await poll()).data.error).toBe("authorization_pending");
  expect((await api("/api/account/device/approve", "POST", { userCode: code.user_code }, "")).status).toBe(401);
  expect((await api(`/api/account/device?user_code=${encodeURIComponent(code.user_code)}`)).status).toBe(200);
  expect((await api("/api/account/device/approve", "POST", { userCode: code.user_code })).status).toBe(200);
  expect((await poll("another-client")).status).not.toBe(200);
  // Respect the plugin's interval after the pending request.
  await Bun.sleep(5100);
  const grant = await poll(); expect(grant.status).toBe(200); expect(grant.data.access_token).toBeTruthy();
  expect(grant.data.access_token).not.toBe(owner.token);
  expect((await api("/api/cloud/account", "GET", undefined, grant.data.access_token)).data.user.id).toBe(owner.user.id);
  expect((await poll()).status).not.toBe(200);
  expect((await api("/api/account/sign-out", "POST", {}, grant.data.access_token)).status).toBe(200);
  expect((await api("/api/cloud/account", "GET", undefined, grant.data.access_token)).status).toBe(401);
  expect((await api("/api/cloud/account")).status).toBe(200);
}, 15000);

test("lost VM creation replies recover the same computer without another purchase or VM", async () => {
  const id = (await api("/api/cloud/computers", "POST", purchase())).data.computer.id;
  await api(`/api/cloud/computers/${id}/checkout`, "POST");
  const before = creates; loseCreateReply = true;
  expect((await api(`/api/cloud/computers/${id}/reconcile`, "POST")).status).toBe(503);
  expect((await api(`/api/cloud/computers/${id}`)).data.computer.state).toBe("paid");
  const recovered = await api(`/api/cloud/computers/${id}/reconcile`, "POST");
  expect(recovered.status).toBe(200); expect(recovered.data.computer.workspaceId).toBeTruthy();
  expect(creates - before).toBe(1);
});

test("concurrent recovery serializes one computer while independent purchases do not share a global lock", async () => {
  const ids = await Promise.all(Array.from({ length: 2 }, async () => {
    const id = (await api("/api/cloud/computers", "POST", purchase())).data.computer.id;
    await api(`/api/cloud/computers/${id}/checkout`, "POST"); return id;
  }));
  const results = await Promise.all(ids.flatMap(id => [api(`/api/cloud/computers/${id}/reconcile`, "POST"), api(`/api/cloud/computers/${id}/reconcile`, "POST")]));
  expect(results.filter(r => r.status === 200)).toHaveLength(2);
  expect(results.filter(r => r.status === 409)).toHaveLength(2);
  for (const id of ids) expect((await api(`/api/cloud/computers/${id}`)).data.computer.workspaceId).toBeTruthy();
});

test("only the computer owner can obtain the unchanged provider runtime JWT", async () => {
  const vm = [...computers.values()][0].id;
  const path = `/api/cloud/provider/workspace/${vm}/runtime-api-access/token`;
  const before = providerRequests.length;
  expect((await api(path, "GET", undefined, stranger.token)).status).toBe(404);
  expect((await api(path, "GET", undefined, "")).status).toBe(401);
  expect(providerRequests).toHaveLength(before);
  const result = await api(path);
  expect(result.status).toBe(200);
  expect(result.data.token).toBeTruthy();
  expect(result.data.token).toBe(issuedRuntimeTokens.get(vm));
  expect(result.data.token).not.toBe(owner.token);
  expect((await api("/api/cloud/account", "GET", undefined, result.data.token)).status).toBe(401);
  expect((await api(`/api/cloud/provider/workspace/${vm}/stop`, "POST")).status).toBe(200);
  const account = await fetch(url + "/api/cloud/account", { headers: { Authorization: `Bearer ${owner.token}` } });
  expect(account.headers.get("X-Frame-Options")).toBe("DENY");
  expect(account.headers.get("Content-Security-Policy")).toBe("frame-ancestors 'none'");
}, 10000);


let controlID = 0;
function control<T = any>(action: string, value = ""): Promise<T> {
  const id = ++controlID;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { child.off("message", listener); reject(new Error("Fixture control timeout")); }, 10000);
    function listener(message: any) {
      if (message.id !== id) return;
      clearTimeout(timer); child.off("message", listener);
      if (message.error) reject(new Error(message.error)); else resolve(message.value);
    }
    child.on("message", listener); child.send({ id, action, value });
  });
}

test("Max preserves the Xcode preset and its approved 24 GB / 240 GB contract", async () => {
  const created = await api("/api/cloud/computers", "POST", { ...purchase(), planId: "max", imageId: "mac-xcode" });
  expect(created.status).toBe(201);
  expect(created.data.computer.plan).toMatchObject({ monthlyCents: 9900, vcpus: 8, memoryMb: 24576, diskGb: 240 });
  const id = created.data.computer.id;
  await api(`/api/cloud/computers/${id}/checkout`, "POST");
  const ready = await api(`/api/cloud/computers/${id}/reconcile`, "POST");
  expect(ready.status).toBe(200);
  expect([...computers.values()].find(c => c.id === ready.data.computer.workspaceId)).toMatchObject({ preset: "macos-xcode", enableKvm: true, cpus: 8, memoryMb: 24576, diskMb: 240 * 1024 });
});

test("canceling an unpaid checkout permits another selection but paid checkout cannot be discarded", async () => {
  const id = (await api("/api/cloud/computers", "POST", purchase())).data.computer.id;
  await api(`/api/cloud/computers/${id}/checkout`, "POST");
  expect((await api(`/api/cloud/computers/${id}/checkout/cancel`, "POST")).status).toBe(409);
  paid = false;
  expect((await api(`/api/cloud/computers/${id}/checkout/cancel`, "POST")).status).toBe(200);
  expect((await api(`/api/cloud/computers/${id}`)).data.computer.state).toBe("deleted");
  expect((await api(`/api/cloud/computers/${id}/checkout`, "POST")).data.computer.state).toBe("deleted");
  paid = true;
});

test("renewal preserves paid access and interrupted deletion can finish without affecting another computer", async () => {
  const id = (await api("/api/cloud/computers", "POST", purchase())).data.computer.id;
  await api(`/api/cloud/computers/${id}/checkout`, "POST");
  const ready = (await api(`/api/cloud/computers/${id}/reconcile`, "POST")).data.computer;
  const other = [...computers.values()].find(c => c.id !== ready.workspaceId)!;
  expect((await api(`/api/cloud/computers/${id}/subscription/cancel`, "POST")).data.computer.subscription.cancelAtPeriodEnd).toBe(true);
  expect((await api(`/api/cloud/computers/${id}/subscription/resume`, "POST")).data.computer.subscription.cancelAtPeriodEnd).toBe(false);
  loseDeleteReply = true;
  const path = `/api/cloud/provider/workspace/${ready.workspaceId}`;
  expect((await api(path, "DELETE")).status).toBe(503);
  expect((await api(`/api/cloud/computers/${id}`)).data.computer.state).toBe("deleting");
  expect((await api(path + "/start", "POST")).status).toBe(409);
  expect((await api(path, "DELETE")).status).toBe(200);
  expect((await api(`/api/cloud/computers/${id}`)).data.computer.state).toBe("deleted");
  expect([...computers.values()].some(c => c.id === other.id)).toBe(true);
});

test("explicit account linking preserves existing push IDs and hashes, renews credentials and cannot change ownership", async () => {
  const before = await control("legacyPush");
  const nativeDevice = await api("/api/notifications/devices", "POST", { device_id: "old-phone", fcm_token: "fixture-rotated-device-token", platform: "ios" });
  expect(nativeDevice.status).toBe(201);
  const duplicate = await api("/api/notifications/tokens", "POST", { tag: "old-daemon" });
  expect(duplicate.status).toBe(201);
  const linked = await api("/api/cloud/legacy/link", "POST", { token: "fixture-previous-account-session" });
  expect(linked.status).toBe(200);
  expect((await api("/api/notifications/send", "POST", { title: "Closed duplicate" }, duplicate.data.token.token)).status).toBe(401);
  expect((await api("/api/cloud/legacy/link", "POST", { token: "fixture-previous-account-session" }, stranger.token)).status).toBe(409);
  const devices = (await api("/api/notifications/devices")).data.devices;
  expect(devices.some((d: any) => d.id === before.device.id)).toBe(true);
  expect((await api("/api/notifications/tokens")).data.tokens.some((t: any) => t.id === before.minted.id)).toBe(true);
  const sent = await api("/api/notifications/send", "POST", { title: "Fixture only" }, before.minted.token);
  expect(sent.data.delivered).toBe(1);
  expect((await control<string[][]>("sent")).at(-1)).toEqual(["fixture-rotated-device-token"]);
  await control("refreshLegacy", owner.user.id);
  expect((await api("/api/cloud/legacy/status")).data.connected).toBe(true);
  expect(previousTokens.has("fixture-previous-account-session")).toBe(false);
  expect((await api("/api/notifications/devices")).data.devices.some((d: any) => d.id === before.device.id)).toBe(true);
  expect((await api(`/api/notifications/devices/${nativeDevice.data.device.id}`, "DELETE")).status).toBe(200);
  expect((await api("/api/notifications/devices/status?device_id=old-phone")).data.registered).toBe(false);
  expect((await api("/api/notifications/send", "POST", { title: "No delivery after unregister" }, before.minted.token)).data.delivered).toBe(0);
});


test("production account cookies are host-only and Secure, including device approval login", async () => {
  const production = spawn("node", ["--import", require.resolve("tsx"), new URL("./fixtures/cloud-server.ts", import.meta.url).pathname], {
    stdio: ["ignore", "pipe", "pipe", "ipc"], env: { ...process.env, NODE_ENV: "production", CONSOLE_MODE: "cloud", BASE_URL: "https://console.mindwire.test",
      DATABASE_URL: "", POSTGRES_HOST: "", AUTH_DB_PATH: join(directory, "production-auth.db"), AUTH_SECRET: randomBytes(48).toString("base64url"),
      SECRETS_ENCRYPTION_KEY: randomBytes(32).toString("base64url"), SEED_DEFAULT_DAEMON: "false" },
  });
  try {
    const address = await new Promise<string>((resolve, reject) => {
      let log = ""; production.stderr?.on("data", data => log = (log + data).slice(-2000));
      production.on("message", (m: any) => { if (m.ready) resolve(m.ready); });
      production.once("exit", code => reject(new Error(`Production fixture exited ${code}: ${log}`)));
      setTimeout(() => reject(new Error("Production fixture timed out")), 10000).unref();
    });
    const response = await fetch(address + "/api/account/sign-up/email", { method: "POST", headers: { "Content-Type": "application/json", Origin: "https://console.mindwire.test" },
      body: JSON.stringify({ email: "secure@example.test", password: "fixture-password-123456", name: "Secure cookies" }) });
    expect(response.status).toBe(200);
    expect(response.headers.get("X-Frame-Options")).toBe("DENY");
    expect(response.headers.get("Content-Security-Policy")).toBe("frame-ancestors 'none'");
    const cookies = response.headers.getSetCookie();
    expect(cookies.length).toBeGreaterThan(0);
    for (const cookie of cookies) {
      expect(cookie.startsWith("__Host-mindwire.")).toBe(true);
      expect(cookie).toMatch(/; Secure(?:;|$)/i);
      expect(cookie).toMatch(/; Path=\/(?:;|$)/i);
      expect(cookie).not.toMatch(/; Domain=/i);
    }
  } finally { production.kill("SIGTERM"); }
}, 15000);


test("renaming through native management updates Console without changing the original purchase retry", async () => {
  const input = purchase();
  const id = (await api("/api/cloud/computers", "POST", input)).data.computer.id;
  await api(`/api/cloud/computers/${id}/checkout`, "POST");
  const result = await api(`/api/cloud/computers/${id}/reconcile`, "POST");
  expect(result.status).toBe(200);
  const computer = result.data.computer;
  expect((await api(`/api/cloud/provider/workspace/${computer.workspaceId}`, "PUT", { name: "Renamed computer" })).status).toBe(200);
  expect((await api(`/api/cloud/computers/${id}`)).data.computer.name).toBe("Renamed computer");
  const retry = await api("/api/cloud/computers", "POST", input);
  expect(retry.status).toBe(201); expect(retry.data.computer.id).toBe(id);
});


test("linked native and previous-account requests rotate one delivery channel atomically", async () => {
  await api("/api/notifications/devices", "POST", { device_id: "rotation-phone", fcm_token: "rotation-token", platform: "ios" });
  const previous = [...previousTokens][0];
  const minted = await Promise.all(Array.from({ length: 8 }, (_, i) => api("/api/notifications/tokens", "POST", { tag: "one-channel" }, i % 2 ? owner.token : previous)));
  expect(minted.every(r => r.status === 201)).toBe(true);
  expect(new Set(minted.map(r => r.data.token.id)).size).toBe(1);
  const outcomes = await Promise.all(minted.map(r => api("/api/notifications/send", "POST", { title: "One active credential" }, r.data.token.token)));
  expect(outcomes.filter(r => r.status === 200)).toHaveLength(1);
});
