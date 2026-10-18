import type { Context } from "hono";
import { auth } from "../auth";
import { env } from "../env";
import { OperationError } from "../errors";

export async function accountSession(c: Context) {
  const identity = await auth.api.getSession({ headers: c.req.raw.headers });
  if (!identity?.user.id)
    throw new OperationError(401, "unauthorized", "Sign in to Mindwire.");
  if (
    c.req.header("Cookie") &&
    !["GET", "HEAD"].includes(c.req.method) &&
    !env.trustedOrigins.includes(c.req.header("Origin") ?? "")
  )
    throw new OperationError(
      403,
      "untrusted_origin",
      "Start this action from your Mindwire account.",
    );
  return identity;
}

export async function accountUser(c: Context) {
  return (await accountSession(c)).user;
}
