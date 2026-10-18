import type { Context } from "hono";
import type { ComputerService } from "./service";
import { cloudBody } from "./access";
import { CloudError } from "./types";
import { legacyClient, legacyCredential } from "./legacy";
import { providerBase, providerClient } from "./provider";
import { forwardComputer } from "./proxy";

/** Collection operations still go through owner-bound namespace credentials.
 * No customer-chosen path is ever retried with the reseller's admin key. */
export async function computerCollection(c: Context, owner: string, path: string, service: ComputerService): Promise<Response | null> {
  const rows = (await service.store.list(owner)).filter(row => row.workspace_id && !["deleting", "deleted"].includes(row.state));
  const legacy = await legacyClient(owner);
  if (path === "/namespaces" && c.req.method === "GET") {
    const data = rows.map(row => ({ id: row.namespace, slug: row.namespace, name: row.name, status: "active" }));
    if (legacy) data.push(...(await legacy.namespaces.list({ limit: 100 })).data.map(n => ({ id: n.id, slug: n.slug, name: n.name, status: n.status })));
    return c.json({ success: true, data, pagination: { total: data.length, limit: data.length, offset: 0 } });
  }
  if (path === "/zone/mine" && c.req.method === "GET") {
    // Only public egress selection fields leave the infrastructure boundary.
    const result = await service.provider.master()._http.request<{ proxies: Array<{ ip: string; country_code?: string }> }>({ method: "GET", path });
    return c.json({ proxies: result.proxies.map(p => ({ ip: p.ip, country_code: p.country_code })) });
  }
  if (path.startsWith("/github/")) {
    // Preserve already-connected GitHub App installations under the verified
    // previous account. New Mindwire GitHub connections use their own adapter.
    if (!legacy && path === "/github/status") return c.json({ connected: false, available: false });
    if (!legacy) throw new CloudError(409, "github_connection_required", "Connect GitHub in Mindwire, or add your own GitHub token in Settings.");
    if (!/^\/github\/(?:user\/orgs|repos\/user|orgs\/[A-Za-z0-9_.-]+\/repos|repos\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/clone-token|status|connect(?:\/.*)?|install(?:\/.*)?|installations(?:\/.*)?|disconnect)$/.test(path))
      throw new CloudError(404, "unsupported_cloud_operation", "GitHub operation not found.");
    const query = new URL(c.req.url).searchParams;
    for (const key of ["user_id", "client_id", "namespace", "owner_id"]) query.delete(key);
    return forwardComputer(c, providerBase(), path, (await legacyCredential(owner))!, query);
  }
  if (!(path === "/disks" || path.startsWith("/disks/"))) return null;
  if (!/^\/disks(?:\/[A-Za-z0-9_.-]+)*$/.test(path)) throw new CloudError(400, "invalid_disk", "Invalid disk request.");
  const query = new URL(c.req.url).searchParams;
  for (const key of ["namespace", "user_id", "client_id", "owner_id"]) query.delete(key);
  if (path === "/disks" && c.req.method === "GET") {
    const disks: unknown[] = [];
    for (const row of rows) {
      const client = await service.provider.scoped(row.namespace);
      const result = await client._http.request<{ disks: unknown[] }>({ method: "GET", path, query: { namespace: row.namespace } });
      disks.push(...result.disks);
    }
    if (legacy) disks.push(...(await legacy._http.request<{ disks: unknown[] }>({ method: "GET", path })).disks);
    return c.json({ success: true, disks });
  }
  let body: Record<string, unknown> | undefined;
  if (!["GET", "HEAD"].includes(c.req.method)) body = await cloudBody(c);
  const workspace = /^\/disks\/workspace\/([A-Za-z0-9_-]+)/.exec(path)?.[1] ??
    (typeof body?.workspace_id === "string" ? body.workspace_id : query.get("workspace_id"));
  let row = rows.find(row => row.workspace_id === workspace);
  if (!workspace && typeof body?.namespace === "string") row = rows.find(row => row.namespace === body.namespace);
  const disk = /^\/disks\/((?!library(?:\/|$)|operations(?:\/|$)|workspace(?:\/|$))[A-Za-z0-9_-]+)/.exec(path)?.[1];
  const operation = /^\/disks\/operations\/([A-Za-z0-9_-]+)/.exec(path)?.[1];
  let token: string | null = null;
  const candidates = row ? [row] : rows;
  if (disk || operation) {
    for (const candidate of candidates) {
      const credential = await service.provider.scopedToken(candidate.namespace);
      try {
        await providerClient({ token: credential })._http.request({ method: "GET", path: operation ? `/disks/operations/${operation}` : `/disks/${disk}` });
        row = candidate; token = credential; break;
      } catch (error) { if (!(error instanceof CloudError) || error.status !== 404) throw error; }
    }
  } else if (row) token = await service.provider.scopedToken(row.namespace);
  else if (path === "/disks/library" && rows[0]) { row = rows[0]; token = await service.provider.scopedToken(row.namespace); }
  if (!token && legacy) {
    if (workspace) await legacy.workspaces.get(workspace);
    if (disk || operation) await legacy._http.request({ method: "GET", path: operation ? `/disks/operations/${operation}` : `/disks/${disk}` });
    token = await legacyCredential(owner);
  }
  if (!token) throw new CloudError(404, "disk_not_found", "Choose a Cloud Computer or a disk belonging to your account.");
  if (body) {
    for (const key of ["user_id", "client_id", "owner_id"]) delete body[key];
    if (row) {
      if (typeof body.to_namespace === "string" && body.to_namespace !== row.namespace)
        throw new CloudError(409, "disk_transfer_required", "Moving storage between computer subscriptions requires a reviewed transfer.");
      if (path === "/disks" && c.req.method === "POST") body.namespace = row.namespace;
      else delete body.namespace;
    }
  }
  return forwardComputer(c, providerBase(), path, token, query, body ? JSON.stringify(body) : undefined);
}
