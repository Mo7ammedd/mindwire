import { sql } from "drizzle-orm";
import { createHash } from "node:crypto";
import { consoleRows, consoleWriteBatch } from "../database";
import { encrypt } from "../secrets";
import type { DeviceRow, TokenRow } from "./types";
import { PushError } from "./types";

export function tokenHash(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

/** The same bound SQL is compiled by Drizzle for PostgreSQL and SQLite. */
export const pushRows = consoleRows;

/** A verified account link is an alias, not a destructive data migration. Both
 * existing device ids and send-token hashes remain valid across the transition. */
function ownerCondition(owner: string) {
  const alias = owner.startsWith("console:")
    ? sql`(SELECT 'oblien:' || provider_id FROM cloud_legacy_account WHERE owner_id=${owner.slice(8)})`
    : owner.startsWith("oblien:")
      ? sql`(SELECT 'console:' || owner_id FROM cloud_legacy_account WHERE provider_id=${owner.slice(7)})`
      : sql`NULL`;
  return sql`owner_id IN (${owner}, ${alias})`;
}

function canonicalOwner(owner: string) {
  return owner.startsWith("console:") ? sql`COALESCE((SELECT 'oblien:' || provider_id FROM cloud_legacy_account WHERE owner_id=${owner.slice(8)}),${owner})` : sql`${owner}`;
}

function ownerCanRegister(owner: string) {
  if (owner.startsWith("console:")) return sql`EXISTS (SELECT 1 FROM "user" WHERE id=${owner.slice(8)})
    AND NOT EXISTS (SELECT 1 FROM account_deletion WHERE owner_id=${owner.slice(8)})`;
  return sql`NOT EXISTS (SELECT 1 FROM account_deletion d JOIN cloud_legacy_account a ON a.owner_id=d.owner_id
    WHERE 'oblien:' || a.provider_id=${owner})`;
}

/** Shared with account linking. Stable lock order prevents a rotation from
 * racing the moment two authenticated notification owners become aliases. */
export function pushMutationLocks(owner: string) {
  const locks = [sql`SELECT pg_advisory_xact_lock(hashtext(${owner}))`];
  if (owner.startsWith("console:")) locks.push(sql`SELECT pg_advisory_xact_lock(hashtext(${canonicalOwner(owner)}))`);
  return locks;
}

export class PushStore {
  async devices(owner: string): Promise<DeviceRow[]> {
    return pushRows<DeviceRow>(sql`SELECT * FROM push_device WHERE ${ownerCondition(owner)} ORDER BY last_seen_at DESC,id DESC`);
  }

  async device(owner: string, deviceId: string): Promise<DeviceRow | undefined> {
    return (await pushRows<DeviceRow>(sql`SELECT * FROM push_device WHERE ${ownerCondition(owner)} AND device_id=${deviceId} ORDER BY last_seen_at DESC,id DESC`))[0];
  }

  async register(owner: string, deviceId: string, token: string, platform: string, info: object | null): Promise<DeviceRow> {
    const now = Date.now();
    // A single upsert preserves the device id across token refreshes. Secrets are
    // encrypted with the existing Console vault key, never returned by reads.
    const row = (await pushRows<DeviceRow>(sql`
      INSERT INTO push_device(owner_id,device_id,token_ciphertext,token_hash,platform,device_info,status,created_at,last_seen_at)
      SELECT ${canonicalOwner(owner)},${deviceId},${encrypt(token)},${tokenHash(token)},${platform},${info ? JSON.stringify(info) : null},'active',${now},${now}
      WHERE ${ownerCanRegister(owner)}
      ON CONFLICT(owner_id,device_id) DO UPDATE SET token_ciphertext=excluded.token_ciphertext,
        token_hash=excluded.token_hash,platform=excluded.platform,device_info=excluded.device_info,status='active',last_seen_at=excluded.last_seen_at
      RETURNING *`))[0];
    if (!row) throw new PushError(409, "account_deletion_pending");
    return row;
  }

  async removeDevice(owner: string, id: number): Promise<void> {
    await pushRows(sql`DELETE FROM push_device WHERE ${ownerCondition(owner)} AND device_id IN
      (SELECT device_id FROM push_device WHERE ${ownerCondition(owner)} AND id=${id}) RETURNING id`);
  }

  async pruneDevice(row: DeviceRow): Promise<void> {
    // A delayed FCM rejection must not revoke a concurrently refreshed token.
    await pushRows(sql`UPDATE push_device SET status='revoked' WHERE id=${row.id} AND owner_id=${row.owner_id} AND token_hash=${row.token_hash} RETURNING id`);
  }

  async tokens(owner: string, workspace: string | null = null, tag: string | null = null): Promise<TokenRow[]> {
    return pushRows<TokenRow>(sql`SELECT * FROM push_token WHERE ${ownerCondition(owner)}
      ${workspace ? sql`AND workspace_id=${workspace}` : sql``}
      ${tag ? sql`AND tag=${tag}` : sql``} ORDER BY created_at DESC`);
  }

  async mint(owner: string, input: { workspace: string | null; tag: string | null; name: string | null; metadata: object | null; expires: number | null }, secret: string): Promise<TokenRow> {
    // Unique (owner,tag) makes refresh/rotation atomic across API replicas.
    const results = await consoleWriteBatch([
      sql`UPDATE push_token SET status='revoked',revoked_at=${Date.now()} WHERE ${ownerCondition(owner)}
        AND tag=${input.tag} AND owner_id<>${canonicalOwner(owner)} RETURNING id`,
      sql`INSERT INTO push_token(owner_id,workspace_id,tag,token_hash,token_prefix,name,metadata,status,created_at,expires_at)
      SELECT ${canonicalOwner(owner)},${input.workspace},${input.tag},${tokenHash(secret)},${secret.slice(0,12)},${input.name},${input.metadata ? JSON.stringify(input.metadata) : null},'active',${Date.now()},${input.expires}
      WHERE ${ownerCanRegister(owner)}
      ON CONFLICT(owner_id,tag) DO UPDATE SET token_hash=excluded.token_hash,token_prefix=excluded.token_prefix,
        workspace_id=excluded.workspace_id,name=excluded.name,metadata=excluded.metadata,status='active',expires_at=excluded.expires_at,revoked_at=NULL
      RETURNING *`,
    ], pushMutationLocks(owner));
    if (!results[1][0]) throw new PushError(409, "account_deletion_pending");
    return results[1][0] as TokenRow;
  }

  async resolve(secret: string): Promise<TokenRow | undefined> {
    return (await pushRows<TokenRow>(sql`SELECT * FROM push_token WHERE token_hash=${tokenHash(secret)} AND status='active' AND (expires_at IS NULL OR expires_at>${Date.now()})`))[0];
  }

  async revoke(owner: string, id: number | string): Promise<boolean> {
    return (await pushRows(sql`UPDATE push_token SET status='revoked',revoked_at=${Date.now()}
      WHERE ${ownerCondition(owner)} AND ${typeof id === "number" ? sql`id=${id}` : sql`tag=${id}`} RETURNING id`)).length > 0;
  }

  async removeToken(owner: string, id: number): Promise<void> {
    await pushRows(sql`DELETE FROM push_token WHERE ${ownerCondition(owner)} AND id=${id} RETURNING id`);
  }

  async touch(id: number): Promise<void> {
    await pushRows(sql`UPDATE push_token SET last_used_at=${Date.now()} WHERE id=${id} RETURNING id`);
  }
}
