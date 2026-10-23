// Hosted Mindwire account identity, shared by the native app and account portal.
import type { Context } from "hono";
import { betterAuth } from "better-auth";
import { getMigrations } from "better-auth/db/migration";
import { bearer, deviceAuthorization } from "better-auth/plugins";
import { APIError } from "better-auth/api";
import { accountDeletionPending } from "./account/deletion-state";

import { env } from "./env";
import { authDatabase, migrateConsoleDatabase } from "./database";
import { emailDeliveryEnabled, sendPasswordResetEmail } from "./email";
import type { PublicConfig, SocialProvider } from "../shared/api";

/** Base path the Better Auth handler is mounted on — kept distinct from the agent-auth `/api/auth/*`. */
export const AUTH_BASE_PATH = "/api/account";

// SQLite needs a local directory; Postgres is the SaaS path and has no filesystem state in this process.
export const consoleDatabase = authDatabase;

/** Offer a social provider only when both credentials are configured. */
const socialProviders = {
  ...(env.social.github ? { github: env.social.github } : {}),
  ...(env.social.google ? { google: env.social.google } : {}),
  ...(env.social.apple ? { apple: env.social.apple } : {}),
};

/** Console owns Mindwire accounts. Personal computers authenticate independently. */
export const auth = betterAuth({
  database: consoleDatabase,
  databaseHooks: {
    session: { create: { before: async (session) => {
      if (await accountDeletionPending(session.userId))
        throw new APIError("FORBIDDEN", { code: "ACCOUNT_DELETION_PENDING", message: "Your Mindwire account is being deleted." });
    } } },
    account: {
      create: { before: async (account) => {
        if (await accountDeletionPending(account.userId))
          throw new APIError("FORBIDDEN", { code: "ACCOUNT_DELETION_PENDING", message: "Your Mindwire account is being deleted." });
      } },
      update: { before: async (account) => {
        if (account.userId && await accountDeletionPending(account.userId))
          throw new APIError("FORBIDDEN", { code: "ACCOUNT_DELETION_PENDING", message: "Your Mindwire account is being deleted." });
      } },
    },
  },
  emailAndPassword: {
    enabled: true,
    autoSignIn: true,
    resetPasswordTokenExpiresIn: 60 * 60,
    revokeSessionsOnPasswordReset: true,
    ...(emailDeliveryEnabled
      ? {
          sendResetPassword: ({
            user,
            url,
          }: {
            user: { email: string };
            url: string;
          }) => sendPasswordResetEmail(user.email, url),
        }
      : {}),
  },
  socialProviders,
  secret: env.authSecret,
  baseURL: env.baseUrl,
  basePath: AUTH_BASE_PATH,
  trustedOrigins: [
    ...env.trustedOrigins,
    ...(env.social.apple ? ["https://appleid.apple.com"] : []),
  ],
  plugins: [
    bearer(),
    deviceAuthorization({
      expiresIn: "10m",
      interval: "5s",
      verificationUri: new URL("/device", env.baseUrl).href,
      validateClient: (client) => client === "mindwire-native",
    }),
  ],
  // Better Auth otherwise prepends __Secure- before custom names. Use explicit
  // Secure attributes so production cookies retain the browser-enforced __Host-
  // prefix: guest computer subdomains cannot plant a parent-domain auth cookie.
  advanced: {
    // A persistent Node server can finish SMTP delivery after the response. Avoid exposing account
    // existence through SMTP latency; Better Auth retains its own token and rate-limit handling.
    backgroundTasks: {
      handler: (task) => {
        void task.catch(() =>
          console.error("[console] Account background task failed."),
        );
      },
    },
    useSecureCookies: false,
    cookiePrefix: env.isProd ? "__Host-mindwire" : "mindwire",
    defaultCookieAttributes: {
      secure: env.isProd,
      path: "/",
      httpOnly: true,
      sameSite: "lax",
    },
  },
});

/** Which social providers are actually clickable — the single source of truth for the login screen. */
export function enabledSocials(): SocialProvider[] {
  return Object.keys(socialProviders) as SocialProvider[];
}

/**
 * The secret-free config the login gate is allowed to read before any user exists (served at
 * `/api/public-config`, the one endpoint the guard lets through unauthenticated). Carries branding, the
 * deployment mode, the available social buttons, and external links — never a client secret.
 */
export function publicConfig(): PublicConfig {
  return {
    appName: env.appName,
    mode: env.mode,
    socials: enabledSocials(),
    passwordResetEnabled: emailDeliveryEnabled,
    docsUrl: env.docsUrl,
    githubUrl: env.githubUrl,
  };
}

// Run the schema migrations once at boot (creates user/session/account/verification). Memoized so the
// guard middleware can `await` it cheaply on the first request without racing a second run.
let migrated: Promise<void> | null = null;
export function initAuth(): Promise<void> {
  if (!migrated) {
    migrated = (async () => {
      // Compose waits for Postgres's healthcheck before it starts the console, but a new Docker network
      // can still take a moment to publish its DNS entry. Retrying here makes SaaS boot deterministic
      // without masking a permanently incorrect DATABASE_URL: after the bounded window we exit clearly.
      const attempts = env.databaseUrl ? 30 : 1;
      for (let attempt = 1; attempt <= attempts; attempt += 1) {
        try {
          const { runMigrations } = await getMigrations(auth.options);
          await runMigrations();
          await migrateConsoleDatabase();
          return;
        } catch (error) {
          if (attempt === attempts) throw error;
          const message =
            error instanceof Error ? error.message : String(error);
          console.warn(
            `[console] database unavailable (${attempt}/${attempts}); retrying in 1s: ${message}`,
          );
          await new Promise<void>((resolve) => setTimeout(resolve, 1_000));
        }
      }
    })();
  }
  return migrated;
}

/**
 * Resolve the authenticated user id from the request's Better Auth session cookie, or `null` when the
 * request carries no valid session. Never throws — a malformed/expired cookie is simply "not signed in".
 */
export async function userIdFromRequest(c: Context): Promise<string | null> {
  try {
    const res = await auth.api.getSession({ headers: c.req.raw.headers });
    return res?.user?.id ?? null;
  } catch {
    return null;
  }
}
