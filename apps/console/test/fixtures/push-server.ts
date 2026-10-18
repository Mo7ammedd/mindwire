// Private child-process controls, never test endpoints on a deployed server.
import { Hono } from "hono";
import { serve } from "@hono/node-server";
import { sql } from "drizzle-orm";
import { auth, initAuth } from "../../server/auth";
import { registerAuth } from "../../server/guard";
import { registerNotifications } from "../../server/notifications/routes";
import { PushStore, pushRows } from "../../server/notifications/store";
import { PushService } from "../../server/notifications/service";
import { importPushData } from "../../server/notifications/import";
import { authDatabase } from "../../server/database";
import { Pool } from "pg";
import type { PushMessage, PushTransport } from "../../server/notifications/types";

await initAuth();
const store = new PushStore();
const sent: Array<{ tokens: string[]; message: PushMessage }> = [];
let rotate = false;
const transport: PushTransport = {
  async validate(token) { return { valid: !token.startsWith("invalid") }; },
  async send(tokens, message) {
    sent.push({ tokens, message });
    const invalidTokens = tokens.filter(token => token === "dead-token");
    if (rotate && invalidTokens.length) {
      await store.register("oblien:1", "rotating-device", "fresh-token", "ios", null);
      rotate = false;
    }
    return { delivered: tokens.length - invalidTokens.length, failed: invalidTokens.length, invalidTokens, errors: [] };
  },
};
const app = new Hono();
registerAuth(app);
registerNotifications(app, new PushService(store, transport));
app.get("/api/private", c => c.json({ ok: true }));
const server = serve({ fetch: app.fetch, port: 0, hostname: "127.0.0.1" }, info => {
  process.send?.({ ready: `http://127.0.0.1:${info.port}` });
});
process.on("message", async (message: { id: number; action: string; value?: any }) => {
  try {
    let value: unknown = true;
    switch (message.action) {
      case "clear":
        await pushRows(sql`DELETE FROM push_token RETURNING id`);
        await pushRows(sql`DELETE FROM push_device RETURNING id`);
        sent.length = 0;
        break;
      case "expire": await pushRows(sql`UPDATE push_token SET expires_at=1 WHERE id=${message.value} RETURNING id`); break;
      case "rotate": rotate = true; break;
      case "sent": value = sent; break;
      case "stored": value = await pushRows(sql`SELECT token_ciphertext FROM push_device`); break;
      case "newAccount": {
        const response = await auth.api.signUpEmail({ body: { email: `push-${Date.now()}@example.test`, password: "fixture-password-123456", name: "Push test" }, asResponse: true });
        value = response.headers.get("set-cookie")?.split(";")[0];
        break;
      }
      case "import":
        if (!(authDatabase instanceof Pool)) throw new Error("PostgreSQL required");
        value = await importPushData(message.value.snapshot, authDatabase, message.value.apply);
        break;
      default: throw new Error("Unknown fixture control");
    }
    process.send?.({ id: message.id, value });
  } catch (error) { process.send?.({ id: message.id, error: String(error) }); }
});
process.on("disconnect", () => server.close(() => process.exit(0)));
