import { sql, type SQL } from "drizzle-orm";
import { createHash } from "node:crypto";
import { postgres, sqlite } from "../database";
import { encrypt } from "../secrets";
import type { DeviceRow, TokenRow } from "./types";

export function tokenHash(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

/** The same bound SQL is compiled by Drizzle for PostgreSQL and SQLite. */
export async function pushRows<T extends Record<string, unknown>>(query: SQL): Promise<T[]> {
  if (postgres) return (await postgres.execute<T>(query)).rows as T[];
  return sqlite!.all<T>(query);
}

export class PushStore {
  async devices(owner: string): Promise<DeviceRow[]> {
    return pushRows<DeviceRow>(sql`SELECT * FROM push_device WHERE owner_id=${owner} ORDER BY last_seen_at DESC`);
  }

  async device(owner: string, deviceId: string): Promise<DeviceRow | undefined> {
    return (await pushRows<DeviceRow>(sql`SELECT * FROM push_device WHERE owner_id=${owner} AND device_id=${deviceId}`))[0];
  }

  async register(owner: string, deviceId: string, token: string, platform: string, info: object | null): Promise<DeviceRow> {
    const now = Date.now();
    // A single upsert preserves the device id across token refreshes. Secrets are
    // encrypted with the existing Console vault key, never returned by reads.
    return (await pushRows<DeviceRow>(sql`
      INSERT INTO push_device(owner_id,device_id,token_ciphertext,token_hash,platform,device_info,status,created_at,last_seen_at)
      VALUES(${owner},${deviceId},${encrypt(token)},${tokenHash(token)},${platform},${info ? JSON.stringify(info) : null},'active',${now},${now})
      ON CONFLICT(owner_id,device_id) DO UPDATE SET token_ciphertext=excluded.token_ciphertext,
        token_hash=excluded.token_hash,platform=excluded.platform,device_info=excluded.device_info,status='active',last_seen_at=excluded.last_seen_at
      RETURNING *`))[0];
  }

  async removeDevice(owner: string, id: number): Promise<void> {
    await pushRows(sql`DELETE FROM push_device WHERE owner_id=${owner} AND id=${id} RETURNING id`);
  }

  async pruneDevice(row: DeviceRow): Promise<void> {
    // A delayed FCM rejection must not revoke a concurrently refreshed token.
    await pushRows(sql`UPDATE push_device SET status='revoked' WHERE id=${row.id} AND owner_id=${row.owner_id} AND token_hash=${row.token_hash} RETURNING id`);
  }

  async tokens(owner: string, workspace: string | null = null, tag: string | null = null): Promise<TokenRow[]> {
    return pushRows<TokenRow>(sql`SELECT * FROM push_token WHERE owner_id=${owner}
      ${workspace ? sql`AND workspace_id=${workspace}` : sql``}
      ${tag ? sql`AND tag=${tag}` : sql``} ORDER BY created_at DESC`);
  }

  async mint(owner: string, input: { workspace: string | null; tag: string | null; name: string | null; metadata: object | null; expires: number | null }, secret: string): Promise<TokenRow> {
    // Unique (owner,tag) makes refresh/rotation atomic across API replicas.
    return (await pushRows<TokenRow>(sql`
      INSERT INTO push_token(owner_id,workspace_id,tag,token_hash,token_prefix,name,metadata,status,created_at,expires_at)
      VALUES(${owner},${input.workspace},${input.tag},${tokenHash(secret)},${secret.slice(0,12)},${input.name},${input.metadata ? JSON.stringify(input.metadata) : null},'active',${Date.now()},${input.expires})
      ON CONFLICT(owner_id,tag) DO UPDATE SET token_hash=excluded.token_hash,token_prefix=excluded.token_prefix,
        workspace_id=excluded.workspace_id,name=excluded.name,metadata=excluded.metadata,status='active',expires_at=excluded.expires_at,revoked_at=NULL
      RETURNING *`))[0];
  }

  async resolve(secret: string): Promise<TokenRow | undefined> {
    return (await pushRows<TokenRow>(sql`SELECT * FROM push_token WHERE token_hash=${tokenHash(secret)} AND status='active' AND (expires_at IS NULL OR expires_at>${Date.now()})`))[0];
  }

  async revoke(owner: string, id: number | string): Promise<boolean> {
    return (await pushRows(sql`UPDATE push_token SET status='revoked',revoked_at=${Date.now()}
      WHERE owner_id=${owner} AND ${typeof id === "number" ? sql`id=${id}` : sql`tag=${id}`} RETURNING id`)).length > 0;
  }

  async removeToken(owner: string, id: number): Promise<void> {
    await pushRows(sql`DELETE FROM push_token WHERE owner_id=${owner} AND id=${id} RETURNING id`);
  }

  async touch(id: number): Promise<void> {
    await pushRows(sql`UPDATE push_token SET last_used_at=${Date.now()} WHERE id=${id} RETURNING id`);
  }
}
