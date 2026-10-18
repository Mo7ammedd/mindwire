/** One-time, fail-closed import. No live endpoint accepts migration records. */
import type { Pool } from "pg";
import { encrypt } from "../secrets";
import { tokenHash } from "./store";
import { object } from "./service";

function string(value: unknown, max: number): string {
  if (typeof value !== "string" || !value.length || value.length > max) throw new Error("Invalid push export string");
  return value;
}
function id(value: unknown): number {
  const result = Number(value);
  if (!Number.isSafeInteger(result) || result <= 0) throw new Error("Invalid push export id");
  return result;
}
function owner(value: unknown): string {
  const raw = String(value);
  if (!/^[1-9]\d*$/.test(raw)) throw new Error("Invalid push export owner");
  return `oblien:${raw}`;
}
function time(value: unknown, required = false): number | null {
  if (value == null && !required) return null;
  const result = typeof value === "number" ? value : Date.parse(String(value));
  if (!Number.isSafeInteger(result) || result < 0) throw new Error("Invalid push export timestamp");
  return result;
}
function json(value: unknown): string | null {
  if (value == null) return null;
  const result = object(typeof value === "string" ? JSON.parse(value) : value);
  return JSON.stringify(result);
}
function status(value: unknown): string {
  if (value !== "active" && value !== "revoked") throw new Error("Invalid push export status");
  return value;
}

export async function importPushData(input: unknown, pool: Pool, apply = false) {
  const snapshot = object(input);
  if (snapshot.format !== "mindwire-push-export-v1" || !Array.isArray(snapshot.devices) || !Array.isArray(snapshot.tokens)) throw new Error("Invalid push export format");
  const devices = snapshot.devices.map(value => {
    const row = object(value);
    const token = string(row.fcm_token, 4096);
    const platform = string(row.platform, 16);
    if (!["ios", "android", "web"].includes(platform)) throw new Error("Invalid push export platform");
    return { id: id(row.id), owner_id: owner(row.user_id), device_id: string(row.device_id, 255),
      token_hash: tokenHash(token), token_ciphertext: encrypt(token), platform,
      device_info: json(row.device_info), status: status(row.status),
      created_at: time(row.created_at, true)!, last_seen_at: time(row.last_seen_at) };
  });
  const tokens = snapshot.tokens.map(value => {
    const row = object(value), hash = string(row.token_hash, 64);
    if (!/^[a-f0-9]{64}$/.test(hash)) throw new Error("Invalid push export token hash");
    return { id: id(row.id), owner_id: owner(row.user_id), workspace_id: row.workspace_id == null ? null : string(row.workspace_id, 255),
      tag: row.tag == null ? null : string(row.tag, 120), token_hash: hash, token_prefix: string(row.token_prefix, 16),
      name: row.name == null ? null : string(row.name, 120), metadata: json(row.metadata), status: status(row.status),
      created_at: time(row.created_at, true)!, last_used_at: time(row.last_used_at), expires_at: time(row.expires_at), revoked_at: time(row.revoked_at) };
  });
  const unique = (values: unknown[], label: string) => { if (new Set(values).size !== values.length) throw new Error(`Duplicate push export ${label}`); };
  unique(devices.map(row => row.id), "device id");
  unique(devices.map(row => JSON.stringify([row.owner_id, row.device_id])), "device ownership");
  unique(tokens.map(row => row.id), "token id");
  unique(tokens.map(row => row.token_hash), "token hash");
  unique(tokens.filter(row => row.tag != null).map(row => JSON.stringify([row.owner_id, row.tag])), "token tag");
  const owners = new Set([...devices, ...tokens].map(row => row.owner_id)).size;
  const report = { devices: devices.length, tokens: tokens.length, owners, applied: false };
  if (!apply) return report;
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    await client.query("SET LOCAL lock_timeout='5s'");
    await client.query("SET LOCAL statement_timeout='15s'");
    await client.query("LOCK TABLE push_device,push_token IN ACCESS EXCLUSIVE MODE");
    // Never replace live target rows or silently import a partial snapshot.
    const counts = (await client.query("SELECT (SELECT count(*) FROM push_device)::int devices,(SELECT count(*) FROM push_token)::int tokens")).rows[0];
    if (counts.devices || counts.tokens) throw new Error("Push target is not empty; import refused without changing it");
    for (const row of devices) await client.query(
      "INSERT INTO push_device(id,owner_id,device_id,token_ciphertext,token_hash,platform,device_info,status,created_at,last_seen_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)",
      [row.id, row.owner_id, row.device_id, row.token_ciphertext, row.token_hash, row.platform, row.device_info, row.status, row.created_at, row.last_seen_at]);
    for (const row of tokens) await client.query(
      "INSERT INTO push_token(id,owner_id,workspace_id,tag,token_hash,token_prefix,name,metadata,status,created_at,last_used_at,expires_at,revoked_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)",
      [row.id, row.owner_id, row.workspace_id, row.tag, row.token_hash, row.token_prefix, row.name, row.metadata, row.status, row.created_at, row.last_used_at, row.expires_at, row.revoked_at]);
    for (const table of ["push_device", "push_token"]) await client.query(
      `SELECT setval(pg_get_serial_sequence('${table}','id'),COALESCE(MAX(id),1),MAX(id) IS NOT NULL) FROM ${table}`);
    // Compare every imported public routing/security field inside the transaction.
    const importedDevices = (await client.query("SELECT * FROM push_device ORDER BY id")).rows;
    const importedTokens = (await client.query("SELECT * FROM push_token ORDER BY id")).rows;
    for (const [expected, actual] of [[devices, importedDevices], [tokens, importedTokens]] as const) {
      const sorted = [...expected].sort((a, b) => a.id - b.id);
      if (sorted.length !== actual.length) throw new Error("Push import count mismatch");
      sorted.forEach((row, index) => {
        for (const [key, value] of Object.entries(row)) {
          const stored = actual[index][key];
          if (typeof value === "number" ? Number(stored) !== value : stored !== value) throw new Error("Push import verification failed");
        }
      });
    }
    await client.query("COMMIT");
    return { ...report, applied: true };
  } catch (error) { await client.query("ROLLBACK"); throw error; }
  finally { client.release(); }
}
