import { registerNotifications } from "../../server/notifications/routes";
import { PushService } from "../../server/notifications/service";
import { PushStore } from "../../server/notifications/store";
import { refreshLegacyAccounts } from "../../server/cloud/legacy";
import { Hono } from "hono";
import { serve } from "@hono/node-server";
import { runtimeHostBoundary } from "../../server/cloud/runtime-origin";
import { cloudWebSockets } from "../../server/cloud/websocket";
import { initAuth } from "../../server/auth";
import { registerAuth } from "../../server/guard";
import { registerCloud } from "../../server/cloud/routes";
import { sql } from "drizzle-orm";
import { consoleRows } from "../../server/database";

await initAuth();
const app = new Hono(); app.use("*", runtimeHostBoundary); registerAuth(app); registerCloud(app);
const pushStore = new PushStore();
const sent: string[][] = [];
const pushService = new PushService(pushStore, {
  async validate() { return { valid: true }; },
  async send(tokens) { sent.push(tokens); return { delivered: tokens.length, failed: 0, invalidTokens: [], errors: [] }; },
});
registerNotifications(app, pushService);
const server = serve({ fetch: app.fetch, websocket: { server: cloudWebSockets }, port: 0, hostname: "127.0.0.1" }, info => process.send?.({ ready: `http://127.0.0.1:${info.port}` }));
process.on("message", async ({ id, action, value }: { id: number; action: string; value: string }) => {
  try {
    let result: unknown;
    if (action === "expireLease") result = await consoleRows(sql`UPDATE cloud_computer SET lease_until=1 WHERE id=${value} RETURNING id`);
    else if (action === "stored") result = await consoleRows(sql`SELECT * FROM cloud_computer WHERE id=${value}`);
    else if (action === "legacyPush") {
      const device = await pushStore.register("oblien:73", "old-phone", "fixture-existing-device-token", "ios", null);
      const minted = await pushService.mint("oblien:73", { tag: "old-daemon", device_id: "old-phone" });
      result = { device, minted };
    }
    else if (action === "refreshLegacy") {
      await consoleRows(sql`UPDATE cloud_legacy_account SET next_refresh_at=0 WHERE owner_id=${value} RETURNING owner_id`);
      await refreshLegacyAccounts(); result = true;
    }
    else if (action === "sent") result = sent;
    else throw new Error("Unknown fixture control");
    process.send?.({ id, value: result });
  } catch (error) { process.send?.({ id, error: String(error) }); }
});
process.on("disconnect", () => server.close(() => process.exit(0)));
