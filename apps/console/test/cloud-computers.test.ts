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
let checkoutFailure: { status: number; code: string } | undefined;
let loseCancelReply = false, cancelLeavesOpen = false, genericCancellation = true, customCheckout = false;
let statusFailure = false, statusMismatch = false;
let completeDuringCancel = false;
const cancellationKeys = new Map<string, string>();
const issuedRuntimeTokens = new Map<string, string>();
const providerRequests: Array<{ path: string; method: string; namespace: string | null }> = [];
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
  providerRequests.push({ path, method: request.method, namespace });
  const ok = (value: object) => Response.json({ success: true, ...value });
  if (!master && !namespaces.has(namespace ?? "")) return Response.json({}, { status: 401 });
  if (path === "/disks" && request.method === "GET") {
    const computer = [...computers.values()].find(c => c.namespace === namespace);
    if (!computer) return Response.json({}, { status: 404 });
    return ok({ disks: [{ id: `disk_${computer.id}`, namespace }] });
  }
  if (path === "/workspace/images") return ok({ images: [{ id: "linux", image: "ubuntu:24.04", base_os: { family: "linux" } }, { id: "mac", image: "macos:15", base_os: { family: "macos" }, minimum_resources: { memory_mb: 11264 } }, { id: "mac-xcode", image: "macos:15", preset: "macos-xcode", vm_defaults: { enable_kvm: true }, base_os: { family: "macos" }, minimum_resources: { cpus: 8, memory_mb: 24576 } }] });
  if (path === "/billing/catalog") return ok({ reseller: { checkoutCancellation: genericCancellation } });
  if (path === "/billing/capacity/catalog") return ok({ tariffId: "test-tariff", tariff: { monthly: { minimumCents: 500, vcpuCents: 600, memoryGiBCents: 100, diskGiBCents: 5 } }, paymentSources: { monthly: ["stripe"] } });
  if (path === "/namespaces/ensure" && master) { namespaces.add(body.slug); return ok({ data: { slug: body.slug } }); }
  if (path === "/tokens" && master) return ok({ token: `namespace:${body.namespace}`, scope: "namespace", expiresAt: new Date(Date.now() + 300000).toISOString() });
  if (path === "/billing/checkout" && master) {
    if (checkoutFailure) return Response.json({ code: checkoutFailure.code, error: "private-secret payment details", details: { customer: "private@example.test" } }, { status: checkoutFailure.status });
    let checkout = payments.get(body.idempotencyKey);
    if (!checkout) { checkout = { id: (customCheckout ? "bco_" : "cs_") + payments.size, custom: customCheckout, request: body }; payments.set(body.idempotencyKey, checkout); checkoutWrites++; }
    else expect(checkout.request).toEqual(body);
    if (loseCheckoutReply) { loseCheckoutReply = false; return Response.json({ error: "lost reply" }, { status: 503 }); }
    return ok({ url: checkout.custom ? `https://api.oblien.com/billing/pay#${"a".repeat(43)}` : `https://checkout.stripe.com/c/pay/${checkout.id}`, checkoutId: checkout.id });
  }
  const checkoutView = (checkout: any) => ({ id: checkout.id, kind: "subscription", status: checkout.expired ? "expired" : paid ? "complete" : "open",
    paymentStatus: paid && !checkout.expired ? "paid" : "unpaid", fulfilled: paid && !checkout.expired,
    fulfillmentStatus: checkout.expired ? "expired" : paid ? "completed" : "pending", ...checkout.status });
  if (/^\/billing\/checkout\/(cs|bco)_\d+$/.test(path) && master && request.method === "GET") {
    if (statusFailure) { statusFailure = false; return Response.json({}, { status: 503 }); }
    const checkout = [...payments.values()].find(p => p.id === path.split("/")[3]);
    if (!checkout) return Response.json({}, { status: 404 });
    return ok({ namespace: statusMismatch ? "another-namespace" : checkout.request.namespace, checkout: checkoutView(checkout) });
  }
  if (path === "/billing/capacity" && master) {
    const ns = u.searchParams.get("namespace");
    const checkout = [...payments.values()].find(p => p.request.namespace === ns);
    return ok({ namespace: ns, pendingCheckout: checkout && !checkout.expired ? { checkoutId: checkout.id, url: null,
      quote: { id: `quote_${checkout.id}`, namespace: ns, paymentSource: "stripe" } } : null });
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
  if ((/^\/billing\/checkout\/(cs|bco)_\d+\/cancel$/.test(path) || path === "/billing/capacity/change/cancel") && master) {
    const checkout = [...payments.values()].find(p => path === "/billing/capacity/change/cancel" ? `quote_${p.id}` === body.quoteId : p.id === path.split("/")[3]);
    if (!checkout || checkout.request.namespace !== body.namespace) return Response.json({}, { status: 404 });
    const previous = cancellationKeys.get(checkout.id);
    if (previous) expect(body.idempotencyKey).toBe(previous);
    cancellationKeys.set(checkout.id, body.idempotencyKey);
    if (completeDuringCancel) checkout.status = { status: "complete", paymentStatus: "paid", fulfilled: false, fulfillmentStatus: "pending" };
    else if (!paid && !cancelLeavesOpen) checkout.expired = true;
    if (loseCancelReply) { loseCancelReply = false; return Response.json({}, { status: 503 }); }
    return path === "/billing/capacity/change/cancel" ? ok({ namespace: body.namespace, pendingCheckout: null })
      : ok({ namespace: body.namespace, checkout: checkoutView(checkout) });
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
    NODE_ENV: "test", BASE_URL: "http://127.0.0.1:8787", DATABASE_URL: databaseURL, POSTGRES_HOST: "", AUTH_DB_PATH: join(directory, "auth.db"),
    AUTH_SECRET: randomBytes(48).toString("base64url"), SECRETS_ENCRYPTION_KEY: randomBytes(32).toString("base64url"),
    PUSH_IDENTITY_PROVIDER_URL: fake.url.origin, OBLIEN_CLIENT_ID: "reseller", OBLIEN_CLIENT_SECRET: "private-secret", OBLIEN_BASE_URL: fake.url.origin, OBLIEN_WEBHOOK_SECRET: "fixture-webhook-secret",
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
  const processing = await api(`/api/cloud/computers/${id}/checkout/cancel`, "POST");
  expect(processing.status).toBe(200);
  expect(processing.data.computer.purchase).toMatchObject({ status: "processing", canContinue: false, canCancel: false });
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
    stdio: ["ignore", "pipe", "pipe", "ipc"], env: { ...process.env, NODE_ENV: "production", BASE_URL: "https://console.mindwire.test",
      DATABASE_URL: "", POSTGRES_HOST: "", AUTH_DB_PATH: join(directory, "production-auth.db"), AUTH_SECRET: randomBytes(48).toString("base64url"),
      SECRETS_ENCRYPTION_KEY: randomBytes(32).toString("base64url") },
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

test("account portal lists only owned connections without credentials and revokes by opaque ID", async () => {
  expect((await api("/api/portal/sessions", "GET", undefined, "")).status).toBe(401);
  const email = "portal-sessions@example.test", password = "fixture-password-123456";
  const first = (await api("/api/account/sign-up/email", "POST", { email, password, name: "Portal" }, "")).data;
  const second = await api("/api/account/sign-in/email", "POST", { email, password }, "");
  const listed = await api("/api/portal/sessions", "GET", undefined, first.token);
  expect(listed.status).toBe(200);
  expect(listed.data.sessions).toHaveLength(2);
  expect(listed.data.sessions.filter((s: any) => s.current)).toHaveLength(1);
  for (const session of listed.data.sessions) {
    expect(Object.keys(session).sort()).toEqual(["id", "current", "userAgent", "createdAt", "lastActiveAt", "expiresAt"].sort());
    expect(session.id).not.toBe(first.token);
    expect(session.id).not.toBe(second.data.token);
  }
  const other = listed.data.sessions.find((s: any) => !s.current);
  expect((await api(`/api/portal/sessions/${other.id}/revoke`, "POST", {}, stranger.token)).status).toBe(404);
  const cookie = second.headers.get("set-cookie")!.split(";")[0];
  const forged = await fetch(`${url}/api/portal/sessions/${other.id}/revoke`, {
    method: "POST", headers: { Cookie: cookie, Origin: "https://untrusted.example" },
  });
  expect(forged.status).toBe(403);
  expect((await api(`/api/portal/sessions/${other.id}/revoke`, "POST", {}, first.token)).status).toBe(200);
  expect((await api("/api/portal/sessions", "GET", undefined, second.data.token)).status).toBe(401);
  expect((await api("/api/portal/sessions", "GET", undefined, first.token)).data.sessions).toHaveLength(1);
});

test("profile and password use the existing account API and revoke other connections", async () => {
  const email = "portal-profile@example.test", password = "fixture-password-123456";
  const first = (await api("/api/account/sign-up/email", "POST", { email, password, name: "Before" }, "")).data;
  const second = (await api("/api/account/sign-in/email", "POST", { email, password }, "")).data;
  expect((await api("/api/account/update-user", "POST", { name: "After" }, first.token)).status).toBe(200);
  expect((await api("/api/account/get-session", "GET", undefined, first.token)).data.user.name).toBe("After");
  const changed = await api("/api/account/change-password", "POST", { currentPassword: password, newPassword: "replacement-password-456", revokeOtherSessions: true }, first.token);
  expect(changed.status).toBe(200);
  expect((await api("/api/portal/sessions", "GET", undefined, second.token)).status).toBe(401);
  expect((await api("/api/account/sign-in/email", "POST", { email, password }, "")).status).toBe(401);
  expect((await api("/api/account/sign-in/email", "POST", { email, password: "replacement-password-456" }, "")).status).toBe(200);
});

// Each recovery scenario has its own real account and persisted purchase. Only
// the external provider is a fixture; requests exercise Hono, auth and SQLite/PG.
function recoveryTest(name: string, work: () => Promise<void>) {
  test(name, async () => {
    paid = false;
    try { await work(); }
    finally {
      paid = true; checkoutFailure = undefined; loseCheckoutReply = false;
      loseCancelReply = false; cancelLeavesOpen = false; genericCancellation = true;
      customCheckout = false; statusFailure = false; statusMismatch = false; completeDuringCancel = false;
    }
  });
}
async function recoveryPurchase() {
  const account = (await api("/api/account/sign-up/email", "POST", {
    email: `recovery-${randomBytes(8).toString("hex")}@example.test`, password: "fixture-password-123456", name: "Original purchaser",
  }, "")).data;
  const created = await api("/api/cloud/computers", "POST", purchase(), account.token);
  expect(created.status).toBe(201);
  const id = created.data.computer.id;
  const call = (suffix = "", method = "POST") => api(`/api/cloud/computers/${id}${suffix}`, method, undefined, account.token);
  return { id, token: account.token, call, payment: () => payments.get(`mindwire-computer:${id}:checkout:v1`) };
}

recoveryTest("documented first checkout rejection remains locally cancelable with safe diagnostics", async () => {
  const { call } = await recoveryPurchase();
  const before = checkoutWrites;
  checkoutFailure = { status: 400, code: "billing_redirect_not_allowed" };
  const rejected = await call("/checkout");
  expect(rejected.status).toBe(503);
  expect(rejected.data).toMatchObject({ code: "billing_redirect_not_allowed", details: { retryable: false } });
  expect(rejected.data.details.reference).toBeTruthy();
  expect(JSON.stringify(rejected.data)).not.toMatch(/private-secret|private@example/);
  const saved = await call("", "GET");
  expect(saved.data.computer).toMatchObject({ state: "draft", purchase: { canCancel: true, error: { retryable: false } } });
  const requests = providerRequests.length;
  expect((await call("/checkout/cancel")).data.computer.state).toBe("deleted");
  expect(providerRequests).toHaveLength(requests);
  expect(checkoutWrites).toBe(before);
});

recoveryTest("polling and cancellation never replay an unconfirmed checkout; Resume keeps original terms", async () => {
  const { call, payment, token } = await recoveryPurchase();
  const writes = checkoutWrites; loseCheckoutReply = true;
  expect((await call("/checkout")).status).toBe(503);
  const original = structuredClone(payment().request), calls = providerRequests.length;
  expect((await call("", "GET")).data.computer.purchase).toMatchObject({ status: "recovering", canContinue: true, canCancel: false });
  for (let i = 0; i < 3; i++) expect((await call("/reconcile")).status).toBe(200);
  const canceled = await call("/checkout/cancel");
  expect(canceled.status).toBe(409); expect(canceled.data.code).toBe("checkout_unconfirmed");
  expect(providerRequests).toHaveLength(calls);
  await api("/api/account/update-user", "POST", { name: "Changed after lost reply" }, token);
  const resumed = await call("/checkout");
  expect(resumed.status).toBe(200); expect(resumed.data.computer.state).toBe("payment_pending");
  expect(payment().request).toEqual(original); expect(checkoutWrites - writes).toBe(1);
  expect((await call("/checkout/cancel")).data.computer.state).toBe("deleted");
});

recoveryTest("a later rejection cannot release an earlier uncertain checkout", async () => {
  const { call } = await recoveryPurchase();
  loseCheckoutReply = true;
  expect((await call("/checkout")).status).toBe(503);
  checkoutFailure = { status: 422, code: "invalid_offer" };
  expect((await call("/checkout")).status).toBe(502);
  expect((await call("", "GET")).data.computer.state).toBe("checkout_pending");
  expect((await call("/checkout/cancel")).data.code).toBe("checkout_unconfirmed");
  checkoutFailure = undefined;
  expect((await call("/checkout")).status).toBe(200);
  expect((await call("/checkout/cancel")).data.computer.state).toBe("deleted");
});

recoveryTest("explicit expiry can close an unidentified checkout without replaying payment during cancellation", async () => {
  const { call } = await recoveryPurchase();
  loseCheckoutReply = true;
  expect((await call("/checkout")).status).toBe(503);
  checkoutFailure = { status: 410, code: "capacity_checkout_expired" };
  expect((await call("/checkout")).data.code).toBe("capacity_checkout_expired");
  expect((await call("", "GET")).data.computer.purchase).toMatchObject({ status: "expired", canContinue: false, canCancel: true });
  const requests = providerRequests.length;
  expect((await call("/checkout/cancel")).data.computer.state).toBe("deleted");
  expect(providerRequests).toHaveLength(requests);
});

recoveryTest("a lost status response retains the checkout identity for cancellation", async () => {
  const { call, id } = await recoveryPurchase();
  const writes = checkoutWrites; statusFailure = true;
  expect((await call("/checkout")).status).toBe(503);
  const stored = (await control("stored", id))[0];
  expect(stored.state).toBe("payment_pending"); expect(stored.checkout_id).toBeTruthy();
  expect((await call("/checkout/cancel")).data.computer.state).toBe("deleted");
  expect(checkoutWrites - writes).toBe(1);
});

recoveryTest("lost cancellation replies resolve from the original checkout and remain idempotent", async () => {
  const { call } = await recoveryPurchase();
  await call("/checkout");
  const writes = checkoutWrites; loseCancelReply = true;
  const canceled = await call("/checkout/cancel");
  expect(canceled.status).toBe(200); expect(canceled.data.computer.state).toBe("deleted");
  const requests = providerRequests.length;
  expect((await call("/checkout/cancel")).data.computer.state).toBe("deleted");
  expect(providerRequests).toHaveLength(requests); expect(checkoutWrites).toBe(writes);
});

recoveryTest("pending cancellations preserve their method and key and block reopening payment", async () => {
  const { call, id } = await recoveryPurchase();
  await call("/checkout"); cancelLeavesOpen = true;
  const pending = await call("/checkout/cancel");
  expect(pending.status).toBe(200);
  expect(pending.data.computer).toMatchObject({ checkout: null, purchase: { status: "canceling", canContinue: false, canCancel: true } });
  const original = JSON.parse((await control("stored", id))[0].contract).cancellation;
  expect((await call("/checkout")).data.code).toBe("checkout_cancellation_pending");
  const requests = providerRequests.length;
  await call("/reconcile");
  expect(providerRequests.slice(requests).every(r => r.method === "GET")).toBe(true);
  genericCancellation = false; cancelLeavesOpen = false;
  expect((await call("/checkout/cancel")).data.computer.state).toBe("deleted");
  expect(cancellationKeys.get(original.checkoutId)).toBe(original.idempotencyKey);
  expect(providerRequests.slice(requests).some(r => r.path === "/billing/capacity/change/cancel")).toBe(false);
});

recoveryTest("legacy cancellation uses only the matching namespace capacity quote", async () => {
  const { call } = await recoveryPurchase();
  await call("/checkout"); genericCancellation = false;
  const requests = providerRequests.length;
  const canceled = await call("/checkout/cancel");
  expect(canceled.status).toBe(200); expect(canceled.data.computer.state).toBe("deleted");
  expect(providerRequests.slice(requests).some(r => r.path === "/billing/capacity/change/cancel")).toBe(true);
});

recoveryTest("expired checkout links are hidden and closing them needs no cancellation mutation", async () => {
  const { call, payment } = await recoveryPurchase();
  await call("/checkout"); payment().expired = true;
  const expired = await call("/reconcile");
  expect(expired.data.computer).toMatchObject({ checkout: null, purchase: { status: "expired", canContinue: false, canCancel: true } });
  const requests = providerRequests.length;
  expect((await call("/reconcile")).status).toBe(200);
  expect(providerRequests).toHaveLength(requests);
  expect((await call("/checkout/cancel")).data.computer.state).toBe("deleted");
  expect(providerRequests.slice(requests).every(r => r.method === "GET")).toBe(true);
});

recoveryTest("submitted unpaid payments show processing without canceling or creating a computer", async () => {
  const { call, payment } = await recoveryPurchase();
  await call("/checkout");
  payment().status = { status: "complete", paymentStatus: "unpaid", fulfilled: false, fulfillmentStatus: "pending" };
  const requests = providerRequests.length, writes = checkoutWrites, vms = creates;
  const result = await call("/checkout/cancel");
  expect(result.status).toBe(200);
  expect(result.data.computer).toMatchObject({ state: "payment_pending", checkout: null, purchase: { status: "processing", canContinue: false, canCancel: false } });
  expect((await call("/checkout")).data.computer.checkout).toBeNull();
  await call("/reconcile");
  expect(checkoutWrites).toBe(writes); expect(creates).toBe(vms);
  expect(providerRequests.slice(requests).every(r => r.method === "GET")).toBe(true);
});

recoveryTest("a concurrent payment wins over cancellation and setup waits for paid capacity", async () => {
  const { call } = await recoveryPurchase();
  await call("/checkout"); completeDuringCancel = true;
  const vms = creates, writes = checkoutWrites;
  const result = await call("/checkout/cancel");
  expect(result.status).toBe(200);
  expect(result.data.computer).toMatchObject({ state: "payment_pending", checkout: null, purchase: { status: "processing", canContinue: false, canCancel: false } });
  expect((await call("/reconcile")).data.computer.state).toBe("payment_pending");
  expect(creates).toBe(vms);
  paid = true;
  expect((await call("/reconcile")).data.computer.state).toBe("ready");
  expect(creates - vms).toBe(1); expect(checkoutWrites).toBe(writes);
});

recoveryTest("provider checkout namespace mismatches cannot expose a payment link or cancel a different payment", async () => {
  const { call } = await recoveryPurchase();
  statusMismatch = true;
  expect((await call("/checkout")).data.code).toBe("invalid_checkout");
  expect((await call("", "GET")).data.computer.checkout).toBeNull();
  const requests = providerRequests.length;
  expect((await call("/checkout/cancel")).data.code).toBe("invalid_checkout");
  expect(providerRequests.slice(requests).every(r => r.method === "GET")).toBe(true);
  statusMismatch = false;
  expect((await call("/checkout/cancel")).data.computer.state).toBe("deleted");
});

recoveryTest("opaque Oblien checkout IDs and hosted pages use the same recovery and cancellation flow", async () => {
  const { call } = await recoveryPurchase(); customCheckout = true;
  const opened = await call("/checkout");
  expect(opened.status).toBe(200);
  expect(opened.data.computer.checkout.id).toStartWith("bco_");
  expect(opened.data.computer.checkout.url).toBe(`https://api.oblien.com/billing/pay#${"a".repeat(43)}`);
  expect((await call("/checkout")).data.computer.checkout.id).toBe(opened.data.computer.checkout.id);
  expect((await call("/checkout/cancel")).data.computer.state).toBe("deleted");
});
