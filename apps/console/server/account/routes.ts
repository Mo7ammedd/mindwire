import { Hono } from "hono";
import { auth } from "../auth";
import { operationError, OperationError } from "../errors";
import { accountSession } from "./access";
import { cloudBody } from "../cloud/access";
import { deletionByReceipt, deletionForAccount, deletionProgress, requestAccountDeletion } from "./deletion";
import { enabledSocials } from "../auth";

/** Session credentials remain server-side; browsers manage their connections by opaque ID. */
export function registerAccountPortal(root: Hono) {
  const app = new Hono();
  const confirmations = new Map<string, { count: number; until: number }>();
  app.onError(operationError);
  app.get("/account/deletion/status", async (c) =>
    c.json(await deletionByReceipt(c.req.header("X-Deletion-Receipt") ?? "")));
  app.get("/account/deletion", async (c) => {
    const current = await accountSession(c);
    const pending = await deletionForAccount(current.user.id);
    const accounts = await (await auth.$context).internalAdapter.findAccounts(current.user.id);
    return c.json({
      ...(pending ? deletionProgress(pending) : { status: "none" as const }),
      hasPassword: accounts.some(account => account.providerId === "credential" && Boolean(account.password)),
      needsSignIn: Date.now() - new Date(current.session.createdAt).getTime() >= 10 * 60 * 1000,
      socials: enabledSocials().filter(provider => accounts.some(account => account.providerId === provider)),
    });
  });
  app.post("/account/deletion", async (c) => {
    const current = await accountSession(c), body = await cloudBody(c);
    if (body.expectedUserId !== current.user.id)
      throw new OperationError(409, "account_changed", "Your signed-in account changed. Reopen Account settings before continuing.");
    if (body.confirmation !== "DELETE")
      throw new OperationError(400, "confirmation_required", "Type DELETE to confirm permanent account deletion.");
    if (!(await deletionForAccount(current.user.id))) {
      const now = Date.now();
      if (confirmations.size >= 10000) for (const [id, entry] of confirmations) if (entry.until <= now) confirmations.delete(id);
      const previous = confirmations.get(current.user.id);
      if ((!previous && confirmations.size >= 10000) || previous && previous.until > now && previous.count >= 5)
        throw new OperationError(429, "rate_limit", "Wait a minute before trying account confirmation again.");
      confirmations.set(current.user.id, previous && previous.until > now ? { ...previous, count: previous.count + 1 } : { count: 1, until: now + 60000 });
      const accounts = await (await auth.$context).internalAdapter.findAccounts(current.user.id);
      const hasPassword = accounts.some(account => account.providerId === "credential" && Boolean(account.password));
      if (hasPassword) {
        if (typeof body.password !== "string" || !body.password || body.password.length > 1024)
          throw new OperationError(400, "password_required", "Enter your Mindwire password to confirm.");
        try { await auth.api.verifyPassword({ headers: c.req.raw.headers, body: { password: body.password } }); }
        catch (error) {
          if ((error as { statusCode?: number }).statusCode === 400)
            throw new OperationError(400, "invalid_password", "The password is incorrect.");
          throw error;
        }
      } else if (Date.now() - new Date(current.session.createdAt).getTime() >= 10 * 60 * 1000) {
        throw new OperationError(403, "recent_sign_in_required", "Sign in again before deleting your account.");
      }
    }
    return c.json(await requestAccountDeletion(current.user.id), 202);
  });
  app.get("/sessions", async (c) => {
    const current = await accountSession(c);
    const sessions = await auth.api.listSessions({
      headers: c.req.raw.headers,
    });
    return c.json({
      sessions: sessions.map((session) => ({
        id: session.id,
        current: session.id === current.session.id,
        userAgent: session.userAgent ?? "",
        createdAt: session.createdAt,
        lastActiveAt: session.updatedAt,
        expiresAt: session.expiresAt,
      })),
    });
  });
  app.post("/sessions/:id/revoke", async (c) => {
    const current = await accountSession(c);
    const sessions = await auth.api.listSessions({
      headers: c.req.raw.headers,
    });
    const owned = sessions.find((session) => session.id === c.req.param("id"));
    if (!owned)
      throw new OperationError(
        404,
        "session_not_found",
        "This connection is no longer active.",
      );
    await auth.api.revokeSession({
      headers: c.req.raw.headers,
      body: { token: owned.token },
    });
    return c.json({ revoked: true, current: owned.id === current.session.id });
  });
  root.route("/api/portal", app);
}
