import { randomBytes } from "node:crypto";
import { decrypt } from "../secrets";
import { PushStore } from "./store";
import { PushError, type DeviceRow, type PushTransport, type TokenRow } from "./types";

export function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new PushError(400, "invalid_object");
  return value as Record<string, unknown>;
}
function text(value: unknown, max: number, required = false): string | null {
  if (value == null && !required) return null;
  if (typeof value !== "string" || !value.trim() || value.length > max) throw new PushError(400, "invalid_input");
  return value;
}
function iso(value: number | null): string | null {
  return value == null ? null : new Date(Number(value)).toISOString();
}
export function publicDevice(row: DeviceRow) {
  return { id: row.id, device_id: row.device_id, platform: row.platform, status: row.status,
    device_info: row.device_info ? JSON.parse(row.device_info) : null,
    created_at: iso(row.created_at), last_seen_at: iso(row.last_seen_at) };
}
export function publicToken(row: TokenRow) {
  return { id: row.id, workspace_id: row.workspace_id, tag: row.tag, token_prefix: row.token_prefix,
    name: row.name, metadata: row.metadata ? JSON.parse(row.metadata) : null, status: row.status,
    created_at: iso(row.created_at), last_used_at: iso(row.last_used_at),
    expires_at: iso(row.expires_at), revoked_at: iso(row.revoked_at) };
}

export class PushService {
  constructor(readonly store: PushStore, private transport: PushTransport) {}

  async register(owner: string, input: Record<string, unknown>) {
    const device = text(input.device_id, 255, true)!;
    const token = text(input.fcm_token, 4096, true)!;
    const platform = text(input.platform ?? "ios", 16)!;
    if (!["ios", "android", "web"].includes(platform)) throw new PushError(400, "invalid_platform");
    const info = input.device_info == null ? null : object(input.device_info);
    if (info && Buffer.byteLength(JSON.stringify(info)) > 2048) throw new PushError(413, "device_info_too_large");
    const check = await this.transport.validate(token);
    if (!check.valid) throw new PushError(400, "invalid_device_token");
    return { ...publicDevice(await this.store.register(owner, device, token, platform, info)),
      ...(check.reason ? { token_validation: check.reason } : {}) };
  }

  async mint(owner: string, input: Record<string, unknown>) {
    // These scopes label a delivery channel, not infrastructure permissions.
    // Every token can address only this authenticated owner's own devices.
    const workspace = text(input.workspace_id, 255);
    const tag = text(input.tag, 120)?.trim() ?? null;
    const name = text(input.name, 120);
    const metadata = input.metadata == null ? {} : { ...object(input.metadata) };
    if (input.device_id != null) {
      const device = await this.store.device(owner, text(input.device_id, 255, true)!);
      if (!device) throw new PushError(404, "device_not_found");
      metadata.device_id = device.id;
    }
    if (Buffer.byteLength(JSON.stringify(metadata)) > 2048) throw new PushError(413, "metadata_too_large");
    let expires: number | null = null;
    if (input.expires_in_days != null) {
      const days = input.expires_in_days;
      if (typeof days !== "number" || !Number.isInteger(days) || days < 1 || days > 3650) throw new PushError(400, "invalid_expiry");
      expires = Date.now() + days * 86_400_000;
    }
    const previous = await this.store.tokens(owner, workspace, tag);
    if (!tag && previous.filter(token => token.status === "active").length >= 50) throw new PushError(409, "token_limit");
    const secret = "mwp_" + randomBytes(32).toString("hex");
    const row = await this.store.mint(owner, { workspace, tag, name, metadata, expires }, secret);
    return { ...publicToken(row), refreshed: previous.some(token => token.tag === tag && tag !== null), token: secret };
  }

  async send(row: TokenRow, input: Record<string, unknown>) {
    const title = text(input.title, 256) ?? undefined;
    const body = text(input.body, 2048) ?? undefined;
    if (!title && !body) throw new PushError(400, "message_required");
    const source = input.data == null ? {} : object(input.data);
    const meta = row.metadata ? object(JSON.parse(row.metadata)) : {};
    const data: Record<string, string> = {};
    for (const [key, value] of Object.entries(source)) {
      if (value != null) data[key] = typeof value === "string" ? value : JSON.stringify(value);
    }
    data.channel = typeof meta.channel === "string" ? meta.channel : row.tag ?? row.workspace_id ?? "default";
    if (row.workspace_id) data.workspace_id = row.workspace_id;
    if (row.tag) data.tag = row.tag;
    const message = { title, body, data };
    if (Buffer.byteLength(JSON.stringify(message)) > 3800) throw new PushError(413, "message_too_large");
    const devices = (await this.store.devices(row.owner_id)).filter(device => device.status === "active"
      && (meta.device_id == null || String(meta.device_id) === String(device.id) || String(meta.device_id) === device.device_id));
    if (!devices.length) return { success: true, delivered: 0, failed: 0, devices: 0, detail: "no_active_devices" };
    const tokens = devices.map(device => decrypt(device.token_ciphertext));
    const result = await this.transport.send(tokens, message);
    const dead = new Set(result.invalidTokens);
    for (let i = 0; i < devices.length; i++) if (dead.has(tokens[i])) await this.store.pruneDevice(devices[i]);
    await this.store.touch(row.id);
    return { success: true, delivered: result.delivered, failed: result.failed, devices: devices.length,
      ...(result.errors.length ? { errors: result.errors } : {}) };
  }
}
