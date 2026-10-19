import type { Hono } from "hono";
import { sql } from "drizzle-orm";
import { consoleRows } from "../database";
import { cloudAccount, cloudBody } from "./access";
import { legacyClient, legacyCredential } from "./legacy";
import { providerBase } from "./provider";
import { CloudError, type ComputerRow } from "./types";
import type { ComputerService } from "./service";
import { monthlyComputerImage } from "./images";
import { forwardComputer } from "./proxy";
import { computerCollection } from "./collections";
import { publishComputerPage } from "./pages";

const MANAGEMENT = "/api/cloud/provider";
function relativePath(url: URL, prefix: string): string {
  const path = url.pathname.slice(prefix.length);
  if (!path.startsWith("/") || path.startsWith("//") || path.includes("\\")) throw new CloudError(400, "invalid_path", "Invalid computer request.");
  return path;
}

export function registerComputerGateway(app: Hono, service: ComputerService) {
  app.all(`${MANAGEMENT}/*`, async c => {
    const user = await cloudAccount(c), url = new URL(c.req.url), path = relativePath(url, MANAGEMENT);
    // No encoded path separator can change which resource was checked below.
    if (/%2f|%5c|%25|%2e/i.test(path)) throw new CloudError(400, "invalid_path", "Invalid computer resource.");
    const query = new URLSearchParams(url.search);
    for (const key of ["namespace", "client_id", "user_id", "owner_id"]) query.delete(key);
    if (path === "/workspace/images" && c.req.method === "GET") {
      const catalog = await service.provider.master().workspaces.images.list();
      return c.json(url.searchParams.get("monthly") === "true" ? { ...catalog, images: catalog.images.filter(monthlyComputerImage) } : catalog);
    }
    if (path === "/workspace" && c.req.method === "GET") {
      const rows = (await service.store.list(user.id)).filter(r => r.workspace_id && r.state !== "deleting");
      const workspaces = [];
      for (const row of rows) workspaces.push(await (await service.provider.scoped(row.namespace)).workspaces.get(row.workspace_id!));
      const legacy = await legacyClient(user.id);
      if (legacy) {
        let page = 1;
        for (;;) {
          const result = await legacy.workspaces.list({ page, limit: 100 });
          workspaces.push(...result.workspaces);
          if (!result.workspaces.length || page * 100 >= result.total) break;
          if (++page > 100) throw new CloudError(503, "inventory_too_large", "Contact Mindwire to load this computer inventory.");
        }
      }
      const page = Math.max(1, Math.min(10000, Number(url.searchParams.get("page")) || 1));
      const limit = Math.max(1, Math.min(100, Number(url.searchParams.get("limit")) || 100));
      return c.json({ success: true, workspaces: workspaces.slice((page - 1) * limit, page * limit), total: workspaces.length, page, limit });
    }
    if (path === "/workspace" && c.req.method !== "GET") throw new CloudError(409, "monthly_subscription_required", "Choose a monthly Mindwire Cloud Computer before provisioning.");
    const match = /^\/workspace\/([A-Za-z0-9_-]+)(\/.*)?$/.exec(path);
    if (match) {
      let row: ComputerRow | null = null;
      try { row = await service.store.byWorkspace(user.id, match[1]); }
      catch (error) { if (!(error instanceof CloudError) || error.status !== 404) throw error; }
      const legacy = row ? null : await legacyClient(user.id);
      if (!row && !legacy) throw new CloudError(404, "computer_not_found", "Cloud Computer not found.");
      if (row?.state === "deleting" && !(!match[2] && c.req.method === "DELETE"))
        throw new CloudError(409, "computer_deleting", "Computer cleanup is pending. Retry deletion to finish it.");
      // Personal legacy tokens are only used after the provider confirms that
      // this exact computer belongs to that linked customer.
      if (legacy) await legacy.workspaces.get(match[1]);
      if (match[2] === "/pages" && c.req.method === "POST") {
        const client = row ? await service.provider.scoped(row.namespace) : legacy!;
        return publishComputerPage(c, client, match[1], row?.namespace);
      }
      const token = row ? await service.provider.scopedToken(row.namespace) : (await legacyCredential(user.id))!;
      if (row && !match[2] && c.req.method === "DELETE") {
        return service.store.locked(user.id, row.id, async (current, save) => {
          if (current.state !== "deleting") {
            // Stop renewal first; paid access is kept until the user explicitly
            // deletes the computer. A cancellation failure blocks destructive IO.
            const result = await service.provider.master().billing.cancelSubscription(current.namespace);
            if (result.namespace !== current.namespace || !result.subscription || !(result.subscription.cancelAtPeriodEnd || result.subscription.status === "canceled"))
              throw new CloudError(503, "cancel_unconfirmed", "Renewal could not be stopped. Your computer has been kept; retry deletion.");
            current.state = "deleting"; await save(current);
          }
          try { await (await service.provider.scoped(current.namespace)).workspaces.delete(match[1]); }
          catch (error) { if (!(error instanceof CloudError) || error.status !== 404) throw error; }
          // An accepted asynchronous delete is not proof that resources are gone.
          try {
            await (await service.provider.scoped(current.namespace)).workspaces.get(match[1]);
            throw new CloudError(409, "computer_deleting", "Computer cleanup is still running. Retry shortly to confirm completion.");
          } catch (error) { if (!(error instanceof CloudError) || error.status !== 404) throw error; }
          current.state = "deleted"; await save(current);
          return c.json({ success: true });
        });
      }
      let body: string | undefined, nextName: string | undefined;
      if (!["GET", "HEAD", "DELETE"].includes(c.req.method)) {
        const value = await cloudBody(c);
        for (const key of ["namespace", "client_id", "user_id", "owner_id"]) delete value[key];
        if (row && !match[2] && ["PUT", "PATCH"].includes(c.req.method) && value.name !== undefined) {
          if (typeof value.name !== "string" || !value.name.trim() || value.name.length > 100)
            throw new CloudError(400, "invalid_name", "Enter a computer name up to 100 characters.");
          nextName = value.name.trim(); value.name = nextName;
        }
        body = JSON.stringify(value);
      }
      const response = await forwardComputer(c, providerBase(), path, token, query, body);
      if (response.ok && row && nextName) await consoleRows(sql`UPDATE cloud_computer SET name=${nextName}
        WHERE id=${row.id} AND owner_id=${user.id} AND state NOT IN ('deleting','deleted') RETURNING id`);
      return response;
    }
    const collection = await computerCollection(c, user.id, path, service);
    if (collection) return collection;
    throw new CloudError(404, "unsupported_cloud_operation", "This computer operation is not available through Mindwire yet.");
  });
}
