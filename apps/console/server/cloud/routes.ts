import { createHmac, timingSafeEqual } from "node:crypto";
import { Hono } from "hono";
import { operationError } from "../errors";
import { sql } from "drizzle-orm";
import { env } from "../env";
import { consoleRows } from "../database";
import { COMPUTER_CATALOG_VERSION, COMPUTER_PLANS } from "../../shared/cloud";
import { linkLegacyAccount, legacyStatus, refreshLegacyAccounts } from "./legacy";
import { ComputerService } from "./service";
import { CloudError, contract, publicComputer, type ComputerRow } from "./types";
import { hostedUrl } from "./provider";
import { cloudAccount, cloudBody, cloudRawBody } from "./access";
import { registerComputerGateway } from "./gateway";

export function registerCloud(root: Hono, service = new ComputerService()) {
  const app = new Hono();
  app.onError(operationError);
  app.get("/api/cloud/catalog", c => c.json({ version: COMPUTER_CATALOG_VERSION, currency: "usd", interval: "monthly", plans: COMPUTER_PLANS, available: service.provider.configured() }));
  app.get("/api/cloud/account", async c => {
    const user = await cloudAccount(c);
    return c.json({ authenticated: true, user: { id: user.id, email: user.email, name: user.name, image: user.image } });
  });
  app.get("/api/cloud/computers", async c => c.json({ computers: (await service.store.list((await cloudAccount(c)).id)).map(publicComputer) }));
  app.post("/api/cloud/computers", async c => {
    const user = await cloudAccount(c), body = await cloudBody(c);
    for (const key of ["name", "planId", "imageId", "idempotencyKey"]) if (typeof body[key] !== "string") throw new CloudError(400, "invalid_computer", "Choose a name, image and monthly plan.");
    const row = await service.create(user.id, body as unknown as Parameters<ComputerService["create"]>[1]);
    return c.json({ computer: publicComputer(row) }, 201);
  });
  app.get("/api/cloud/computers/:id", async c => c.json({ computer: publicComputer(await service.store.get((await cloudAccount(c)).id, c.req.param("id"))) }));
  app.post("/api/cloud/computers/:id/checkout", async c => {
    const user = await cloudAccount(c);
    return c.json({ computer: publicComputer(await service.checkout(user.id, c.req.param("id"), { email: user.email, name: user.name })) });
  });
  app.post("/api/cloud/computers/:id/reconcile", async c => c.json({ computer: publicComputer(await service.reconcile((await cloudAccount(c)).id, c.req.param("id"))) }));
  app.post("/api/cloud/computers/:id/checkout/cancel", async c => c.json({ computer: publicComputer(await service.cancelCheckout((await cloudAccount(c)).id, c.req.param("id"))) }));
  for (const action of ["cancel", "resume"] as const) {
    app.post(`/api/cloud/computers/:id/subscription/${action}`, async c => c.json({ computer: publicComputer(await service.subscription((await cloudAccount(c)).id, c.req.param("id"), action)) }));
  }
  app.post("/api/cloud/computers/:id/billing-portal", async c => {
    const row = await service.store.get((await cloudAccount(c)).id, c.req.param("id"));
    const result = await service.provider.master().billing.portal({ namespace: row.namespace, returnUrl: new URL("/computers", env.baseUrl).href });
    if (result.namespace !== row.namespace) throw new CloudError(502, "cloud_scope_mismatch", "Cloud returned a different subscription.");
    return c.json({ url: hostedUrl(result.url, ["billing.stripe.com"]) });
  });
  app.get("/api/cloud/legacy/status", async c => c.json(await legacyStatus((await cloudAccount(c)).id)));
  app.post("/api/cloud/legacy/link", async c => {
    const user = await cloudAccount(c), body = await cloudBody(c);
    if (typeof body.token !== "string") throw new CloudError(400, "invalid_legacy_account", "A previous account credential is required.");
    await linkLegacyAccount(user.id, body.token);
    return c.json({ connected: true });
  });
  // Webhooks only schedule an authoritative read. A payload, even signed, never
  // grants resources or changes paid terms by itself. Replays are harmless.
  app.post("/api/cloud/webhook", async c => {
    const secret = process.env.OBLIEN_WEBHOOK_SECRET;
    if (!secret) throw new CloudError(503, "webhook_unavailable", "Webhook is not configured.");
    const raw = await cloudRawBody(c);
    const signature = (c.req.header("X-Webhook-Signature") ?? "").replace(/^sha256=/, "");
    const expected = createHmac("sha256", secret).update(raw).digest();
    if (!/^[a-f0-9]{64}$/i.test(signature) || !timingSafeEqual(expected, Buffer.from(signature, "hex"))) throw new CloudError(401, "invalid_signature", "Invalid webhook signature.");
    let payload: { namespace?: string; data?: { namespace?: string } };
    try { payload = JSON.parse(raw); } catch { throw new CloudError(400, "invalid_request", "Invalid webhook."); }
    const namespace = payload?.data?.namespace ?? payload?.namespace;
    if (typeof namespace === "string") await consoleRows(sql`UPDATE cloud_computer SET updated_at=0 WHERE namespace=${namespace} AND state NOT IN ('draft','deleting','deleted') RETURNING id`);
    return c.json({ accepted: true });
  });
  registerComputerGateway(app, service);
  root.route("/", app);
}

/** Bounded, fair recovery also runs when the phone/browser closes mid-payment. */
export function startComputerReconciliation(service = new ComputerService()) {
  let running = false;
  const run = async () => {
    if (running) return;
    running = true;
    try {
      await refreshLegacyAccounts();
      if (!service.provider.configured()) return;
      const rows = await consoleRows<ComputerRow>(sql`SELECT * FROM cloud_computer WHERE state IN ('payment_pending','paid','provisioning','ready') AND updated_at<${Date.now() - 60000} AND lease_until<${Date.now()} ORDER BY updated_at ASC LIMIT 10`);
      for (const row of rows) {
        const saved = contract(row);
        try {
          if (saved.checkoutStatus?.status !== "expired" && saved.checkoutError?.retryable !== false)
            await service.reconcile(row.owner_id, row.id);
        }
        catch (error) { console.warn("[cloud] computer reconciliation deferred", row.id, error instanceof CloudError ? error.code : "cloud_unavailable"); }
        // Failed upstream reads get backoff and cannot starve the rest of the fleet.
        await consoleRows(sql`UPDATE cloud_computer SET updated_at=${Date.now()} WHERE id=${row.id} AND lease_until=0 RETURNING id`);
      }
    } finally { running = false; }
  };
  const timer = setInterval(() => { void run().catch(() => console.error("[cloud] reconciliation unavailable")); }, 30000);
  timer.unref();
  return () => clearInterval(timer);
}
