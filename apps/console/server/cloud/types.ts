import type { ComputerPlan, ComputerState } from "../../shared/cloud";

export { OperationError as CloudError } from "../errors";
export interface ComputerContract {
  version: string;
  name?: string;
  plan: ComputerPlan;
  image: string;
  request: Record<string, unknown>;
  checkoutRequest?: Record<string, unknown>;
  subscription?: { status: string; paidThrough: string | null; cancelAtPeriodEnd: boolean };
}
export interface ComputerRow extends Record<string, unknown> {
  id: string; owner_id: string; request_key: string; namespace: string; name: string;
  state: ComputerState; contract: string; workspace_id: string | null;
  checkout_id: string | null; checkout_url: string | null; error: string | null;
  lease_token: string | null; lease_until: number; created_at: number; updated_at: number;
}
export function contract(row: ComputerRow): ComputerContract { return JSON.parse(row.contract) as ComputerContract; }
export function publicComputer(row: ComputerRow) {
  const saved = contract(row);
  return { id: row.id, name: row.name, plan: saved.plan, image: saved.image, state: row.state,
    workspaceId: row.workspace_id, checkout: row.checkout_id && row.checkout_url ? { id: row.checkout_id, url: row.checkout_url } : null,
    subscription: saved.subscription ?? null, error: row.error };
}
