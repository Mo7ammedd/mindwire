import type { Hono } from "hono";
import { auth, AUTH_BASE_PATH, userIdFromRequest } from "./auth";

/** Each account, Cloud, push and directory module owns its authentication boundary. */
export function registerAuth(app: Hono): void {
  app.use("*", async (c, next) => {
    await next();
    c.header("X-Frame-Options", "DENY");
    c.header("Content-Security-Policy", "frame-ancestors 'none'");
    c.header("Referrer-Policy", "no-referrer");
    if (c.req.path.startsWith("/api/")) c.header("Cache-Control", "no-store");
  });
  // A new API must opt into its own boundary or require a Mindwire account by default.
  app.use("*", async (c, next) => {
    const path = c.req.path;
    const ownedBoundaries = [
      AUTH_BASE_PATH,
      "/api/cloud",
      "/api/portal",
      "/api/notifications",
      "/api/computer-directory/v1",
    ];
    if (
      (!path.startsWith("/api/") && !path.startsWith("/events/")) ||
      ["/api/ping", "/api/public-config"].includes(path) ||
      ownedBoundaries.some(
        (prefix) => path === prefix || path.startsWith(prefix + "/"),
      )
    )
      return next();
    if (!(await userIdFromRequest(c)))
      return c.json({ error: "Not authenticated." }, 401);
    return next();
  });
  app.on(["POST", "GET"], `${AUTH_BASE_PATH}/*`, (c) =>
    auth.handler(c.req.raw),
  );
}
