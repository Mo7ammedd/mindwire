import type { Context } from "hono";
import { userIdFromRequest } from "../auth";
import { env } from "../env";
import { PushError } from "./types";

export function bearer(c: Context): string {
  const match = /^Bearer ([^\s]+)$/.exec(c.req.header("Authorization") ?? "");
  if (!match || match[1].length > 8192) throw new PushError(401, "unauthorized");
  return match[1];
}

/** Existing native clients sign in through Oblien. Verify that identity server-side;
 * never trust a submitted user id or decode a JWT without verification. This bridge
 * authenticates management only: send-only daemon credentials resolve locally. */
export async function pushOwner(c: Context): Promise<string> {
  if (c.req.header("Cookie") || c.req.header("Authorization")) {
    const id = await userIdFromRequest(c);
    if (id) {
      if (c.req.header("Cookie") && !["GET", "HEAD"].includes(c.req.method)) {
        const origin = c.req.header("Origin");
        if (!origin || !env.trustedOrigins.includes(origin)) throw new PushError(403, "untrusted_origin");
      }
      const { legacyPushOwner } = await import("../cloud/legacy");
      return await legacyPushOwner(id) ?? `console:${id}`;
    }
  }
  const token = bearer(c);
  const provider = process.env.PUSH_IDENTITY_PROVIDER_URL ?? (env.mode === "cloud" ? "https://api.oblien.com" : "");
  if (!provider) throw new PushError(401, "unauthorized");
  const origin = new URL(provider);
  if (origin.protocol !== "https:" && !["127.0.0.1", "localhost", "[::1]"].includes(origin.hostname)) throw new Error("Push identity provider requires HTTPS");
  let response: Response;
  try {
    response = await fetch(new URL("/auth/status", origin), {
      headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(5000), redirect: "error",
    });
  } catch { throw new PushError(503, "identity_unavailable"); }
  if (response.status >= 500 || response.status === 429) throw new PushError(503, "identity_unavailable");
  if (!response.ok) throw new PushError(401, "unauthorized");
  const result = await response.json() as { authenticated?: boolean; user?: { id?: unknown } };
  const id = result.user?.id;
  if (result.authenticated !== true || typeof id !== "number" || !Number.isSafeInteger(id) || id <= 0) throw new PushError(401, "unauthorized");
  return `oblien:${id}`;
}
