export const NOTIFICATIONS_PATH = "/api/notifications";

export class PushError extends Error {
  constructor(public status: 400 | 401 | 403 | 404 | 409 | 413 | 429 | 503, public code: string) {
    super(code);
  }
}

export interface DeviceRow extends Record<string, unknown> {
  id: number;
  owner_id: string;
  device_id: string;
  token_ciphertext: string;
  token_hash: string;
  platform: string;
  device_info: string | null;
  status: string;
  created_at: number;
  last_seen_at: number | null;
}

export interface TokenRow extends Record<string, unknown> {
  id: number;
  owner_id: string;
  workspace_id: string | null;
  tag: string | null;
  token_hash: string;
  token_prefix: string;
  name: string | null;
  metadata: string | null;
  status: string;
  created_at: number;
  last_used_at: number | null;
  expires_at: number | null;
  revoked_at: number | null;
}

export interface PushMessage {
  title?: string;
  body?: string;
  data: Record<string, string>;
}

export interface DeliveryResult {
  delivered: number;
  failed: number;
  invalidTokens: string[];
  errors: Array<{ code: string; message: string; count: number }>;
}

export interface PushTransport {
  validate(token: string): Promise<{ valid: boolean; reason?: string }>;
  send(tokens: string[], message: PushMessage): Promise<DeliveryResult>;
}
