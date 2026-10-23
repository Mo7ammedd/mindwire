import { sql } from "drizzle-orm";
import { consoleRows, consoleWriteBatch } from "../database";
import { pushMutationLocks } from "../notifications/store";
import { decrypt, encrypt } from "../secrets";
import { providerBase, providerClient } from "./provider";
import { CloudError } from "./types";

interface LegacyRow extends Record<string, unknown> { provider_id: string; owner_id: string; credential: string; next_refresh_at: number }

/** One-time explicit proof of both accounts. Email equality is never ownership. */
export async function linkLegacyAccount(owner: string, token: string): Promise<void> {
  if (token.length < 16 || token.length > 8192 || /\s/.test(token)) throw new CloudError(400, "invalid_legacy_account", "The previous account credential is invalid.");
  const id = await verifiedIdentity(token);
  // An atomic, unique identity link aliases existing notification rows. No
  // device, send-token hash, computer, subscription or volume is reassigned.
  try {
    await consoleWriteBatch([
      sql`INSERT INTO cloud_legacy_account(provider_id,owner_id,credential,next_refresh_at,created_at)
        SELECT ${String(id)},${owner},${encrypt(token)},${Date.now() + 86400000},${Date.now()}
        WHERE EXISTS (SELECT 1 FROM "user" WHERE id=${owner}) AND NOT EXISTS (SELECT 1 FROM account_deletion WHERE owner_id=${owner})
        ON CONFLICT(provider_id) DO UPDATE SET credential=excluded.credential,next_refresh_at=excluded.next_refresh_at
        WHERE cloud_legacy_account.owner_id=excluded.owner_id RETURNING provider_id`,
      // If both accounts already named the same delivery channel, retain the
      // previous daemon credential and close its duplicate in this transaction.
      sql`UPDATE push_token SET status='revoked',revoked_at=${Date.now()} WHERE owner_id=${`console:${owner}`}
        AND tag IN (SELECT tag FROM push_token WHERE owner_id=${`oblien:${id}`} AND tag IS NOT NULL)
        AND EXISTS (SELECT 1 FROM cloud_legacy_account WHERE provider_id=${String(id)} AND owner_id=${owner}) RETURNING id`,
    ], [...pushMutationLocks(`console:${owner}`), sql`SELECT pg_advisory_xact_lock(hashtext(${`oblien:${id}`}))`]);
  } catch (error) {
    const failure = error as { code?: string; cause?: { code?: string } };
    const code = failure.cause?.code ?? failure.code;
    if (code === "23505" || code === "SQLITE_CONSTRAINT_UNIQUE")
      throw new CloudError(409, "account_already_connected", "This account is already connected to a different Mindwire account.");
    throw error;
  }
  const bound = (await consoleRows<LegacyRow>(sql`SELECT * FROM cloud_legacy_account WHERE provider_id=${String(id)} AND owner_id=${owner}`))[0];
  if (!bound) throw new CloudError(409, "account_already_connected", "This account is already connected to a different Mindwire account.");
}

export async function legacyPushOwner(owner: string): Promise<string | null> {
  const row = (await consoleRows<LegacyRow>(sql`SELECT provider_id FROM cloud_legacy_account WHERE owner_id=${owner}`))[0];
  return row ? `oblien:${row.provider_id}` : null;
}

/** Compatibility only: existing computers and paid contracts retain their
 * original owner and terms. New purchases never use this credential. */
export async function legacyClient(owner: string) {
  const credential = await legacyCredential(owner);
  return credential ? providerClient({ token: credential }) : null;
}

export async function legacyCredential(owner: string) {
  const row = (await consoleRows<LegacyRow>(sql`SELECT * FROM cloud_legacy_account WHERE owner_id=${owner}`))[0];
  return row ? decrypt(row.credential) : null;
}

async function verifiedIdentity(token: string): Promise<number> {
  let response: Response;
  try {
    response = await fetch(providerBase() + "/auth/status", { headers: { Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(5000), redirect: "error" });
  } catch { throw new CloudError(503, "account_unavailable", "Your previous account could not be checked. Retry shortly."); }
  if (!response.ok) throw new CloudError(response.status === 401 || response.status === 403 ? 401 : 503,
    "account_unavailable", "Reconnect your previous account if its session has expired.");
  const status = await response.json() as { authenticated?: boolean; user?: { id?: unknown } };
  const id = status.user?.id;
  if (status.authenticated !== true || typeof id !== "number" || !Number.isSafeInteger(id) || id <= 0)
    throw new CloudError(401, "invalid_legacy_account", "Sign in to your previous account before connecting it.");
  return id;
}

export async function legacyStatus(owner: string) {
  const row = (await consoleRows<LegacyRow>(sql`SELECT * FROM cloud_legacy_account WHERE owner_id=${owner}`))[0];
  if (!row) return { connected: false };
  await verifiedIdentity(decrypt(row.credential));
  return { connected: true };
}

/** Renew only a still-valid, provider-verified session. CAS preserves a newer
 * explicit reconnection or another replica's renewal. Expiry never grants access. */
export async function refreshLegacyAccounts(): Promise<void> {
  const now = Date.now();
  const rows = await consoleRows<LegacyRow>(sql`SELECT * FROM cloud_legacy_account WHERE next_refresh_at<${now}
    AND NOT EXISTS (SELECT 1 FROM account_deletion WHERE owner_id=cloud_legacy_account.owner_id) ORDER BY next_refresh_at LIMIT 25`);
  for (const row of rows) {
    let delay = 3600000;
    try {
      const old = decrypt(row.credential);
      if (String(await verifiedIdentity(old)) !== row.provider_id) throw new Error("Identity mismatch");
      const response = await fetch(providerBase() + "/auth/token", { method: "POST", redirect: "error",
        headers: { Authorization: `Bearer ${old}`, "Content-Type": "application/json" },
        body: JSON.stringify({ old_token: old }), signal: AbortSignal.timeout(5000) });
      const next = await response.json() as { token?: string };
      if (!response.ok || typeof next.token !== "string" || next.token.length > 8192 || String(await verifiedIdentity(next.token)) !== row.provider_id)
        throw new Error("Session renewal unconfirmed");
      await consoleRows(sql`UPDATE cloud_legacy_account SET credential=${encrypt(next.token)},next_refresh_at=${now + 86400000}
        WHERE provider_id=${row.provider_id} AND owner_id=${row.owner_id} AND credential=${row.credential} RETURNING provider_id`);
      continue;
    } catch (error) {
      // Preserve stored ownership and device aliases during an upstream outage.
      if (error instanceof CloudError && error.status === 401) delay = 86400000;
      console.warn("[cloud] previous account renewal deferred");
    }
    await consoleRows(sql`UPDATE cloud_legacy_account SET next_refresh_at=${now + delay}
      WHERE provider_id=${row.provider_id} AND credential=${row.credential} RETURNING provider_id`);
  }
}
