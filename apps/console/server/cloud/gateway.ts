import { createHash } from "node:crypto";
import type { Hono } from "hono";
import { sql } from "drizzle-orm";
import { consoleRows } from "../database";
import { cloudAccount, cloudBody } from "./access";
import { legacyClient, legacyCredential } from "./legacy";
import { providerBase } from "./provider";
import { CloudError, type ComputerRow } from "./types";
import type { ComputerService } from "./service";
import { runtimePublicOrigin } from "./runtime-origin";
import { monthlyComputerImage } from "./images";
import { forwardComputer } from "./proxy";
import { computerCollection } from "./collections";

const MANAGEMENT = "/api/cloud/provider";
export const RUNTIME = "/api/cloud/runtime";
const hash = (token: string) => createHash("sha256").update(token).digest("hex");

function relativePath(url: URL, prefix: string): string {
  const path = url.pathname.slice(prefix.length);
  if (!path.startsWith("/") || path.startsWith("//") || path.includes("\\")) throw new CloudError(400, "invalid_path", "Invalid computer request.");
  return path;
}

/** Grant lookup is local. The provider verifies the workspace JWT again; this
 * gate binds it to an owned, non-deleted computer before any data-plane IO. */
export async function runtimeCredential(headers: Headers, hostname?: string): Promise<string> {
  const token = /^Bearer ([^\s]{1,8192})$/.exec(headers.get("Authorization") ?? "")?.[1];
  if (!token) throw new CloudError(401, "unauthorized", "A computer runtime credential is required.");
  const grant = (await consoleRows<{ computer_id: string }>(sql`SELECT computer_id FROM cloud_runtime_grant WHERE token_hash=${hash(token)} AND expires_at>${Date.now()}`))[0];
  if (!grant) throw new CloudError(401, "unauthorized", "Computer access expired. Reconnect to refresh it.");
  let workspace: string;
  if (grant.computer_id.startsWith("legacy:")) {
    const [, owner, id] = grant.computer_id.split(":");
    workspace = id;
    if (!owner || !await legacyCredential(owner)) throw new CloudError(401, "unauthorized", "The previous cloud account is not connected.");
  } else {
    const active = await consoleRows<{ workspace_id: string }>(sql`SELECT workspace_id FROM cloud_computer WHERE id=${grant.computer_id} AND state NOT IN ('deleting','deleted')`);
    if (!active.length) throw new CloudError(401, "unauthorized", "This computer is no longer available.");
    workspace = active[0].workspace_id;
  }
  if (!hostname || hostname !== new URL(runtimePublicOrigin(workspace)).hostname)
    throw new CloudError(403, "runtime_origin_required", "Use this computer’s dedicated Mindwire runtime address.");
  return token;
}

export function runtimeOrigin(): string {
  const url = new URL(process.env.OBLIEN_RUNTIME_URL ?? "https://workspace.oblien.com");
  if (url.username || url.password || url.search || url.hash || url.pathname !== "/" ||
      !(url.protocol === "https:" || (url.protocol === "http:" && ["127.0.0.1", "localhost"].includes(url.hostname)))) throw new Error("Runtime gateway requires an HTTPS origin");
  return url.origin;
}


async function rememberGrant(computer: string, payload: unknown) {
  if (!payload || typeof payload !== "object" || !("token" in payload) || typeof payload.token !== "string") return;
  const token = payload.token;
  if (token.length > 8192 || token.split(".").length !== 3) return; // Raw SSH/runtime credentials are not gateway grants.
  let expiry = Date.now() + 55 * 60000;
  try {
    const claims = JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString());
    if (typeof claims.exp === "number") expiry = Math.min(expiry, claims.exp * 1000);
  } catch { return; }
  if (expiry <= Date.now()) return;
  await consoleRows(sql`INSERT INTO cloud_runtime_grant(token_hash,computer_id,expires_at) VALUES(${hash(token)},${computer},${expiry})
    ON CONFLICT(token_hash) DO UPDATE SET expires_at=excluded.expires_at WHERE cloud_runtime_grant.computer_id=excluded.computer_id RETURNING token_hash`);
}

export function registerComputerGateway(app: Hono, service: ComputerService) {
  app.all(`${RUNTIME}/*`, async c => {
    const token = await runtimeCredential(c.req.raw.headers, new URL(c.req.url).hostname), url = new URL(c.req.url);
    return forwardComputer(c, runtimeOrigin(), relativePath(url, RUNTIME), token, url.searchParams);
  });
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
      const computerId = row?.id ?? `legacy:${user.id}:${match[1]}`;
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
          await consoleRows(sql`DELETE FROM cloud_runtime_grant WHERE computer_id=${current.id} RETURNING token_hash`);
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
      if (match[2]?.startsWith("/runtime-api-access") && response.ok && response.headers.get("Content-Type")?.includes("json")) {
        const data = await response.json(); await rememberGrant(computerId, data);
        return c.json(data);
      }
      return response;
    }
    const collection = await computerCollection(c, user.id, path, service);
    if (collection) return collection;
    throw new CloudError(404, "unsupported_cloud_operation", "This computer operation is not available through Mindwire yet.");
  });
}
