// Configuration for Mindwire’s hosted account and Cloud service.
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";


function str(name: string, fallback: string): string {
  const v = process.env[name];
  return v && v.length > 0 ? v : fallback;
}

function optional(name: string): string | undefined {
  const v = process.env[name];
  return v && v.length > 0 ? v : undefined;
}

/** Parse a comma/space-separated env list into trimmed non-empty entries. */
function list(name: string): string[] {
  return (process.env[name] ?? "")
    .split(/[,\s]+/)
    .map((s) => s.trim())
    .filter(Boolean);
}

/**
 * OAuth app credentials for a social provider, or `undefined` when the operator hasn't configured one.
 * BOTH the id and the secret must be present — a half-configured provider is treated as absent so the
 * login screen never offers a button that can't complete. e.g. `GITHUB_CLIENT_ID` + `GITHUB_CLIENT_SECRET`.
 */
function socialCreds(prefix: string): { clientId: string; clientSecret: string } | undefined {
  const clientId = optional(`${prefix}_CLIENT_ID`);
  const clientSecret = optional(`${prefix}_CLIENT_SECRET`);
  return clientId && clientSecret ? { clientId, clientSecret } : undefined;
}

const isProd = process.env.NODE_ENV === "production";

function authSigningSecret(): string {
  const secret = optional("AUTH_SECRET") ?? optional("SESSION_SECRET");
  if (secret && secret.length >= 32) return secret;
  if (isProd) throw new Error("AUTH_SECRET must be configured with at least 32 random characters in production.");
  return "mindwire-preview-dev-secret-change-me-please-32+";
}

function encryptionKey(): Buffer {
  const configured = optional("SECRETS_ENCRYPTION_KEY");
  if (!configured) {
    if (isProd) {
      throw new Error("SECRETS_ENCRYPTION_KEY is required in production (use a random 32-byte base64url key).");
    }
    // Development must remain zero-config, but production never falls back to the auth signing key.
    return createHash("sha256").update(str("AUTH_SECRET", "mindwire-dev-secret")).digest();
  }
  const value = configured.trim();
  const key = /^[0-9a-f]{64}$/i.test(value)
    ? Buffer.from(value, "hex")
    : Buffer.from(value, "base64url");
  if (key.length !== 32) {
    throw new Error("SECRETS_ENCRYPTION_KEY must be exactly 32 bytes, encoded as base64url or hex.");
  }
  return key;
}

/**
 * An explicit DATABASE_URL always wins. Otherwise a deployment can supply standard Postgres pieces;
 * building the URL here correctly encodes passwords rather than relying on Compose string interpolation.
 * With neither DATABASE_URL nor POSTGRES_HOST, the console uses its SQLite fallback.
 */
function databaseUrl(): string | undefined {
  const explicit = optional("DATABASE_URL");
  if (explicit) return explicit;

  const host = optional("POSTGRES_HOST");
  if (!host) return undefined;

  const password = optional("POSTGRES_PASSWORD");
  if (!password) {
    throw new Error("POSTGRES_PASSWORD is required when POSTGRES_HOST is set");
  }

  const url = new URL("postgresql://localhost");
  url.hostname = host;
  url.port = str("POSTGRES_PORT", "5432");
  url.username = str("POSTGRES_USER", "mindwire");
  url.password = password;
  url.pathname = `/${str("POSTGRES_DB", "mindwire")}`;
  return url.toString();
}

// Better Auth validates the browser Origin against this URL. The hosted deployment has a safe canonical
// default; other production domains must set BASE_URL explicitly (and register the same OAuth callbacks).
const baseUrl = str(
  "BASE_URL",
  isProd ? "https://console.mindwire.sh" : `http://127.0.0.1:${Number(str("PORT", "8787"))}`,
);

export const env = {
  isProd,
  mode: "cloud",
  port: Number(str("PORT", "8787")),

  // ---- branding / external links (surfaced to the login gate via PublicConfig) ----
  /** Product name shown in the login + top-nav chrome. */
  appName: str("APP_NAME", "MindWire"),
  /** External docs URL (the "Docs" links, in-app and on the login screen). */
  docsUrl: str("DOCS_URL", "https://mindwire.sh/docs"),
  /** Public source repository URL (a login footer link, and the GitHub social button's home). */
  githubUrl: str("GITHUB_URL", "https://github.com/oblien/mindwire"),

  /** Origin the app is served from — Better Auth uses it for cookies and origin (CSRF) checks. */
  baseUrl,

  /** Better Auth signing secret. MUST be ≥32 chars and overridden in any real deployment. */
  authSecret: authSigningSecret(),

  /** AES-256-GCM master key for the Console credential vault. Never exposed to the browser. */
  secretsEncryptionKey: encryptionKey(),

  /**
   * Social (OAuth) sign-in apps. Each provider is offered on
   * the login screen only when both its id and secret are set. The OAuth callback URL to register with
   * the provider is `${baseUrl}/api/account/callback/{github|google|apple}`. Secrets stay server-side.
   */
  social: {
    github: socialCreds("GITHUB"),
    google: socialCreds("GOOGLE"),
    // Apple uses a signed client-secret JWT, not an Apple ID password or app password.
    apple: socialCreds("APPLE"),
  },

  /** Account email delivery. These settings stay on the Console server. */
  smtp: {
    host: optional("SMTP_HOST"),
    port: Number(str("SMTP_PORT", "587")),
    user: optional("SMTP_USER"),
    password: optional("SMTP_PASSWORD"),
    from: optional("SMTP_FROM"),
  },

  /** Postgres URL, explicit or assembled from POSTGRES_* settings; otherwise SQLite is used. */
  databaseUrl: databaseUrl(),

  /**
   * SQLite database for local development and source-container smoke tests. The hosted service
   * uses PostgreSQL. Keep a persistent path when running SQLite.
   */
  authDbPath: str(
    "AUTH_DB_PATH",
    isProd ? "/data/auth.db" : fileURLToPath(new URL("../.data/auth.db", import.meta.url)),
  ),

  /**
   * Extra browser origins allowed to call the auth endpoints (CSRF allowlist). `baseUrl` is always
   * trusted; in dev we also trust the Vite dev server so the split-origin proxy works.
   */
  trustedOrigins: (() => {
    const configured = list("TRUSTED_ORIGINS");
    const devDefaults = isProd
      ? []
      : ["http://127.0.0.1:5174", "http://localhost:5174"];
    return [...new Set([baseUrl, ...configured, ...devDefaults])];
  })(),

  /**
   * Built SPA directory, served statically in prod. The server runs from `dist-server/index.js`, so
   * the Vite build sits one level up in `dist/`. Unused in dev (Vite serves the client).
   */
  clientDist: fileURLToPath(new URL("../dist", import.meta.url)),
} as const;

export type Env = typeof env;
