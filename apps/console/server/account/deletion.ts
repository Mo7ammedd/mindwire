import { createHash, createHmac, randomUUID } from "node:crypto";
import type { auth as accountAuth } from "../auth";
import { decryptOAuthToken } from "better-auth/oauth2";
import { sql } from "drizzle-orm";
import { consoleRows, consoleWriteBatch } from "../database";
import { env } from "../env";
import { OperationError, operationFailure } from "../errors";
import { AccountComputerCleanup } from "../cloud/account-deletion";
import { pushMutationLocks } from "../notifications/store";

type Auth = typeof accountAuth;
interface DeletionRow extends Record<string, unknown> {
  id: string; owner_id: string | null; status: "pending" | "deleted";
  requested_at: number; error_code: string | null;
}
const hash = (value: string) => createHash("sha256").update(value).digest("hex");
const receiptFor = (id: string) => createHmac("sha256", env.authSecret).update(`mindwire-account-deletion:${id}`).digest("hex");

export async function deletionForAccount(owner: string) {
  return (await consoleRows<DeletionRow>(sql`SELECT * FROM account_deletion WHERE owner_id=${owner}`))[0];
}

export function deletionProgress(row: DeletionRow) {
  return { status: row.status, requestedAt: Number(row.requested_at),
    message: row.status === "deleted" ? "Your Mindwire account has been deleted." : row.error_code
      ? "Cleanup is taking longer than usual. Mindwire will keep retrying automatically."
      : "Your account is being deleted. This usually takes a few minutes; Cloud cleanup can take longer. You can close this screen." };
}

export async function requestAccountDeletion(owner: string) {
  const id = randomUUID(), now = Date.now();
  const results = await consoleWriteBatch([
    sql`INSERT INTO account_deletion(id,owner_id,receipt_hash,requested_at,updated_at)
      SELECT ${id},${owner},${hash(receiptFor(id))},${now},${now} WHERE EXISTS (SELECT 1 FROM "user" WHERE id=${owner})
      ON CONFLICT(owner_id) DO UPDATE SET receipt_hash=account_deletion.receipt_hash RETURNING *`,
    // Send-only notification tokens must stop working immediately, including
    // the linked previous-account alias. They do not rely on login sessions.
    sql`UPDATE push_token SET status='revoked',revoked_at=${now} WHERE owner_id=${`console:${owner}`}
      OR owner_id IN (SELECT 'oblien:' || provider_id FROM cloud_legacy_account WHERE owner_id=${owner}) RETURNING id`,
  ], [sql`SELECT id FROM "user" WHERE id=${owner} FOR UPDATE`, ...pushMutationLocks(`console:${owner}`)]);
  const row = results[0][0] as DeletionRow | undefined;
  if (!row) throw new OperationError(401, "unauthorized", "Sign in to Mindwire.");
  return { ...deletionProgress(row), receipt: receiptFor(row.id) };
}

/** The opaque receipt reveals only cleanup progress, never identity or Cloud
 * details, and keeps working after every account session has been revoked. */
export async function deletionByReceipt(receipt: string) {
  if (!/^[a-f0-9]{64}$/.test(receipt)) throw new OperationError(404, "not_found", "Deletion request not found.");
  const row = (await consoleRows<DeletionRow>(sql`SELECT * FROM account_deletion WHERE receipt_hash=${hash(receipt)}`))[0];
  if (!row) throw new OperationError(404, "not_found", "Deletion request not found.");
  return deletionProgress(row);
}

async function revokeApple(auth: Auth, owner: string) {
  const context = await auth.$context;
  for (const account of await context.internalAdapter.findAccounts(owner)) {
    if (account.providerId !== "apple") continue;
    const credential = env.social.apple;
    if (!credential) throw new OperationError(503, "apple_revoke_unavailable", "Apple account cleanup is temporarily unavailable.");
    const refresh = account.refreshToken;
    const raw = refresh || account.accessToken;
    if (!raw) throw new OperationError(503, "apple_token_missing", "Apple account cleanup needs its saved authorization.");
    // Better Auth's generic adapter is invariant, although this is the exact
    // runtime context its OAuth utilities consume.
    const token = await decryptOAuthToken(raw, context as unknown as Parameters<typeof decryptOAuthToken>[1]);
    const response = await fetch("https://appleid.apple.com/auth/revoke", {
      method: "POST", redirect: "error", signal: AbortSignal.timeout(15000),
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ client_id: credential.clientId, client_secret: credential.clientSecret,
        token, token_type_hint: refresh ? "refresh_token" : "access_token" }),
    });
    if (!response.ok) throw new OperationError(503, "apple_revoke_unavailable", "Apple account cleanup is temporarily unavailable.");
  }
}

/** Only worker callbacks use the framework's internal adapter: it runs the same
 * account/session/user deletion hooks as Better Auth's synchronous delete API.
 * No credentials or identity are dropped while provider cleanup is uncertain. */
export function startAccountDeletion(auth: Auth) {
  let running = false;
  const cleanup = new AccountComputerCleanup();
  const run = async () => {
    if (running) return;
    running = true;
    try {
      // Leave time for requests admitted before confirmation to finish. New
      // purchases and provider mutations are rejected as soon as the row exists.
      const due = await consoleRows<DeletionRow>(sql`SELECT * FROM account_deletion WHERE status='pending'
        AND requested_at<${Date.now() - 120000} AND updated_at<${Date.now() - 20000} AND lease_until<${Date.now()}
        ORDER BY updated_at ASC LIMIT 5`);
      for (const candidate of due) {
        const fence = randomUUID();
        const row = (await consoleRows<DeletionRow>(sql`UPDATE account_deletion SET lease_token=${fence},lease_until=${Date.now() + 600000}
          WHERE id=${candidate.id} AND status='pending' AND lease_until<${Date.now()} RETURNING *`))[0];
        if (!row?.owner_id) continue;
        const owner = row.owner_id;
        try {
          // Stop paid computers' renewal before spending passes on a slow VM
          // deletion or a still-settling checkout elsewhere in the account.
          const computers = await consoleRows<{ id: string }>(sql`SELECT id FROM cloud_computer WHERE owner_id=${owner}
            ORDER BY CASE WHEN state IN ('paid','provisioning','ready') THEN 0
              WHEN state IN ('draft','checkout_pending','payment_pending') THEN 1 ELSE 2 END, created_at`);
          // Bound each job's work and preserve fairness between customers.
          const computer = computers[0];
          if (computer) {
            if (!(await cleanup.remove(owner, computer.id))) continue;
            const removed = await consoleRows(sql`DELETE FROM cloud_computer WHERE id=${computer.id} AND owner_id=${owner} AND lease_until=0 RETURNING id`);
            if (!removed.length || computers.length > 1) continue;
          }
          await revokeApple(auth, owner);
          // A worker that lost its lease must not finalize another worker's job.
          const owned = await consoleRows(sql`SELECT id FROM account_deletion WHERE id=${row.id} AND lease_token=${fence} AND lease_until>${Date.now()}`);
          if (!owned.length) continue;
          const context = await auth.$context;
          await consoleWriteBatch([
            sql`DELETE FROM push_device WHERE owner_id=${`console:${owner}`} OR owner_id IN
              (SELECT 'oblien:' || provider_id FROM cloud_legacy_account WHERE owner_id=${owner}) RETURNING id`,
            sql`DELETE FROM push_token WHERE owner_id=${`console:${owner}`} OR owner_id IN
              (SELECT 'oblien:' || provider_id FROM cloud_legacy_account WHERE owner_id=${owner}) RETURNING id`,
            sql`DELETE FROM console_secret WHERE owner_id=${owner} RETURNING owner_id`,
            sql`DELETE FROM cloud_legacy_account WHERE owner_id=${owner} RETURNING owner_id`,
          ], pushMutationLocks(`console:${owner}`));
          // Plugin grants are not a foreign-key cascade in Better Auth.
          await context.adapter.deleteMany({ model: "deviceCode", where: [{ field: "userId", value: owner }] });
          await context.adapter.deleteMany({ model: "verification", where: [{ field: "value", value: owner }] });
          await context.internalAdapter.deleteUser(owner);
          await context.internalAdapter.deleteUserSessions(owner);
          await consoleWriteBatch([
            sql`DELETE FROM cloud_computer WHERE owner_id=${owner} RETURNING id`,
            // Keep only an anonymous, expiring receipt; no email or user ID.
            sql`UPDATE account_deletion SET status='deleted',owner_id=NULL,error_code=NULL,updated_at=${Date.now()}
              WHERE id=${row.id} AND lease_token=${fence} RETURNING id`,
          ]);
        } catch (error) {
          const failure = operationFailure(error);
          console.warn("[account] deletion deferred", row.id, failure.code);
          await consoleRows(sql`UPDATE account_deletion SET error_code=${failure.code} WHERE id=${row.id} AND lease_token=${fence} RETURNING id`);
        } finally {
          await consoleRows(sql`UPDATE account_deletion SET lease_token=NULL,lease_until=0,updated_at=${Date.now()}
            WHERE id=${row.id} AND lease_token=${fence} RETURNING id`);
        }
      }
      await consoleRows(sql`DELETE FROM account_deletion WHERE status='deleted' AND updated_at<${Date.now() - 7 * 86400000} RETURNING id`);
    } finally { running = false; }
  };
  const timer = setInterval(() => { void run().catch(() => console.error("[account] deletion recovery unavailable")); }, 30000);
  timer.unref();
  return () => clearInterval(timer);
}
