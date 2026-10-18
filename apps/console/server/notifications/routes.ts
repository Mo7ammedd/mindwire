import { Hono, type Context } from "hono";
import { bodyLimit } from "hono/body-limit";
import { getConnInfo } from "@hono/node-server/conninfo";
import { bearer, pushOwner } from "./auth";
import { FirebasePush } from "./firebase";
import { object, publicDevice, publicToken, PushService } from "./service";
import { PushStore } from "./store";
import { NOTIFICATIONS_PATH, PushError } from "./types";

function id(c: Context): number {
  const raw = c.req.param("id");
  if (!raw || !/^[1-9]\d*$/.test(raw) || !Number.isSafeInteger(Number(raw))) throw new PushError(400, "invalid_id");
  return Number(raw);
}

export function registerNotifications(app: Hono, service = new PushService(new PushStore(), new FirebasePush())): void {
  const route = new Hono();
  const budgets = new Map<string, { count: number; until: number }>();
  function limit(key: string, max: number) {
    const now = Date.now();
    if (budgets.size >= 10_000) for (const [key, value] of budgets) if (value.until <= now) budgets.delete(key);
    const previous = budgets.get(key);
    if (!previous && budgets.size >= 10_000) throw new PushError(429, "rate_limit");
    const value = previous && previous.until > now ? previous : { count: 0, until: now + 60_000 };
    if (++value.count > max) throw new PushError(429, "rate_limit");
    budgets.set(key, value);
  }
  route.onError((error, c) => {
    const e = error instanceof PushError ? error : new PushError(503, "push_unavailable");
    if (e.status === 429 || e.status === 503) c.header("Retry-After", "60");
    if (!(error instanceof PushError)) console.error("[push] request failed; check notification database and deployment configuration");
    return c.json({ success: false, error: e.code, code: e.code }, e.status);
  });
  route.use("*", bodyLimit({ maxSize: 16_384, onError: c => c.json({ success: false, error: "request_too_large" }, 413) }));
  route.use("*", async (c, next) => {
    let source = "local";
    try { source = getConnInfo(c).remote.address ?? source; } catch { /* in-process tests */ }
    limit(`source:${source}`, 600);
    c.header("Cache-Control", "no-store");
    await next();
  });
  const body = async (c: Context) => {
    if (c.req.header("Content-Type")?.split(";", 1)[0].trim().toLowerCase() !== "application/json") throw new PushError(400, "json_required");
    try { return object(await c.req.json()); }
    catch (error) { if (error instanceof PushError) throw error; throw new PushError(400, "invalid_json"); }
  };
  const owner = async (c: Context) => { const value = await pushOwner(c); limit(`owner:${value}`, 120); return value; };
  route.post("/send", async c => {
    const token = await service.store.resolve(bearer(c));
    if (!token) throw new PushError(401, "invalid_token");
    limit(`send:${token.owner_id}`, 60);
    return c.json(await service.send(token, await body(c)));
  });
  route.post("/devices", async c => c.json({ success: true, device: await service.register(await owner(c), await body(c)) }, 201));
  route.get("/devices", async c => c.json({ success: true, devices: (await service.store.devices(await owner(c))).map(publicDevice) }));
  route.get("/devices/status", async c => {
    const who = await owner(c), deviceId = c.req.query("device_id");
    if (!deviceId || deviceId.length > 255) throw new PushError(400, "invalid_device_id");
    const device = await service.store.device(who, deviceId);
    return c.json(device ? { registered: true, ...publicDevice(device) } : { registered: false });
  });
  route.delete("/devices/:id", async c => { await service.store.removeDevice(await owner(c), id(c)); return c.json({ success: true }); });
  route.post("/tokens", async c => c.json({ success: true, token: await service.mint(await owner(c), await body(c)) }, 201));
  route.get("/tokens", async c => c.json({ success: true, tokens: (await service.store.tokens(await owner(c), c.req.query("workspace_id") ?? null, c.req.query("tag") ?? null)).map(publicToken) }));
  route.post("/tokens/revoke-by-tag", async c => {
    const who = await owner(c), input = await body(c);
    if (typeof input.tag !== "string" || !input.tag.trim()) throw new PushError(400, "invalid_tag");
    if (!await service.store.revoke(who, input.tag.trim())) throw new PushError(404, "token_not_found");
    return c.json({ success: true, tag: input.tag, status: "revoked" });
  });
  route.post("/tokens/:id/revoke", async c => {
    if (!await service.store.revoke(await owner(c), id(c))) throw new PushError(404, "token_not_found");
    return c.json({ success: true, id: id(c), status: "revoked" });
  });
  route.delete("/tokens/:id", async c => { await service.store.removeToken(await owner(c), id(c)); return c.json({ success: true }); });
  route.all("*", c => c.json({ success: false, error: "not_found" }, 404));
  app.route(NOTIFICATIONS_PATH, route);
}
