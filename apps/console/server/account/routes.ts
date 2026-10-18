import { Hono } from "hono";
import { auth } from "../auth";
import { operationError, OperationError } from "../errors";
import { accountSession } from "./access";

/** Session credentials remain server-side; browsers manage their connections by opaque ID. */
export function registerAccountPortal(root: Hono) {
  const app = new Hono();
  app.onError(operationError);
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
