import { createHash } from "node:crypto";
import type { MiddlewareHandler } from "hono";
import { env } from "../env";
import { CloudError } from "./types";

/** Untrusted computer apps must never execute on the account origin. A
 * per-computer hostname also isolates guest app cookies between computers. */
export function runtimePublicOrigin(workspace: string): string {
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(workspace)) throw new CloudError(400, "invalid_computer", "Invalid computer identity.");
  const root = new URL(process.env.MINDWIRE_RUNTIME_PUBLIC_URL ?? "https://computers.mindwire.sh");
  if (root.protocol !== "https:" || root.pathname !== "/" || root.username || root.password || root.search || root.hash || root.port || root.origin === new URL(env.baseUrl).origin)
    throw new Error("Mindwire runtime apps require a separate HTTPS origin");
  const hostId = createHash("sha256").update(workspace).digest("hex").slice(0, 40);
  root.hostname = `${hostId}.${root.hostname}`;
  return root.origin;
}

export function isRuntimeHost(origin: string): boolean {
  const root = new URL(process.env.MINDWIRE_RUNTIME_PUBLIC_URL ?? "https://computers.mindwire.sh");
  const url = new URL(origin);
  return url.hostname === root.hostname || url.hostname.endsWith(`.${root.hostname}`);
}

export const runtimeHostBoundary: MiddlewareHandler = async (c, next) => {
  const runtime = isRuntimeHost(new URL(c.req.url).origin);
  if (runtime && !c.req.path.startsWith("/api/cloud/runtime/")) return c.text("Not found", 404);
  await next();
  if (!runtime) {
    c.header("X-Frame-Options", "DENY");
    c.header("Content-Security-Policy", "frame-ancestors 'none'");
    c.header("Referrer-Policy", "no-referrer");
  }
};
