import { createHash } from "node:crypto";
import type { Context } from "hono";
import type { Oblien } from "oblien";
import { cloudBody } from "./access";
import { CloudError } from "./types";

/** Export only through an already ownership-checked computer and scoped client.
 * The app key gives retries a stable page; another computer's page is never reused.
 */
export async function publishComputerPage(c: Context, client: Oblien, workspace: string, namespace?: string) {
  const body = await cloudBody(c);
  if (typeof body.appId !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(body.appId) ||
      typeof body.name !== "string" || !body.name.trim() || body.name.length > 120 ||
      typeof body.path !== "string" || !body.path.startsWith("/") || body.path.length > 4096 ||
      body.path.includes("\0") || body.path.includes("\\") || body.path.split("/").some(p => p === ".." || [".ssh", ".git", ".mindwire", ".codex", ".claude"].includes(p) || p.startsWith(".env")))
    throw new CloudError(400, "invalid_page", "Choose a dedicated static build folder for this app.");
  const slug = "mw-" + createHash("sha256").update(workspace + "\0" + body.appId).digest("hex").slice(0, 28);
  const owned = (page: { source_workspace_id?: string | null; namespace?: string | null }) => {
    if (page.source_workspace_id !== workspace || namespace && page.namespace !== namespace)
      throw new CloudError(409, "page_scope_mismatch", "This page belongs to another computer. It has been kept unchanged.");
  };
  let existing;
  try { existing = (await client.pages.get(slug)).page; }
  catch (error) { if (!(error instanceof CloudError) || error.status !== 404) throw error; }
  let page;
  if (existing) {
    owned(existing);
    page = (await client.pages.deploy(slug, { workspace_id: workspace, path: body.path })).page;
  } else {
    try {
      page = (await client.pages.create({ workspace_id: workspace, path: body.path, name: body.name.trim(), slug, ...(namespace ? { namespace } : {}) })).page;
    } catch (error) {
      if (!(error instanceof CloudError) || error.status !== 409) throw error;
      // A concurrent request can win creation. Verify it before updating anything.
      owned((await client.pages.get(slug)).page);
      page = (await client.pages.deploy(slug, { workspace_id: workspace, path: body.path })).page;
    }
  }
  owned(page);
  if (page.status === "disabled") {
    page = (await client.pages.enable(slug)).page;
    owned(page);
  }
  const url = new URL(page.url);
  if (page.status !== "active" || url.protocol !== "https:" || url.username || url.password)
    throw new CloudError(502, "page_not_ready", "The page is not ready yet. Retry publishing shortly.");
  return c.json({ page: { url: url.href, slug: page.slug } });
}
