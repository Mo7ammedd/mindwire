import type { Context } from "hono";
import { auth } from "../auth";
import { env } from "../env";
import { CloudError } from "./types";

export async function cloudAccount(c: Context) {
  const session = await auth.api.getSession({ headers: c.req.raw.headers });
  if (!session?.user?.id) throw new CloudError(401, "unauthorized", "Sign in to Mindwire.");
  // Cookie mutations require same-origin consent. Native Bearer sessions don't
  // rely on ambient browser credentials and cannot be used in a cross-site form.
  if (c.req.header("Cookie") && !["GET", "HEAD"].includes(c.req.method) && !env.trustedOrigins.includes(c.req.header("Origin") ?? ""))
    throw new CloudError(403, "untrusted_origin", "This action must start from Mindwire Console.");
  return session.user;
}

export async function cloudBody(c: Context): Promise<Record<string, unknown>> {
  const raw = await cloudRawBody(c);
  if (!raw) return {};
  if (!c.req.header("Content-Type")?.toLowerCase().startsWith("application/json")) throw new CloudError(400, "invalid_request", "Send a JSON request.");
  try {
    const value = JSON.parse(raw);
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error();
    return value;
  } catch { throw new CloudError(400, "invalid_request", "Send a JSON object."); }
}

export async function cloudRawBody(c: Context): Promise<string> {
  if (Number(c.req.header("Content-Length") ?? 0) > 65536) throw new CloudError(413, "request_too_large", "This request is too large.");
  const reader = c.req.raw.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const chunk = await reader.read();
      if (chunk.done) break;
      size += chunk.value.byteLength;
      if (size > 65536) { await reader.cancel(); throw new CloudError(413, "request_too_large", "This request is too large."); }
      chunks.push(chunk.value);
    }
  } finally { reader.releaseLock(); }
  return Buffer.concat(chunks).toString("utf8");
}
