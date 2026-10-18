import type { AddDaemonRequest } from "../../shared/api";
import type { ComputerPlan, ComputerState } from "../../shared/cloud";

export class CloudError extends Error {
  constructor(public status: 400 | 401 | 403 | 404 | 409 | 413 | 429 | 502 | 503, public code: string, message: string) { super(message); }
}
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

/** The saved purchase, not a client payload, defines a managed runtime. */
export function computerRuntime(row: ComputerRow): AddDaemonRequest {
  if (!row.workspace_id || ["deleting", "deleted"].includes(row.state))
    throw new CloudError(409, "computer_unavailable", "Finish preparing this Cloud Computer first.");
  const saved = contract(row);
  return { provider: "oblien", computerId: row.id, workspaceId: row.workspace_id,
    label: row.name, image: saved.image, cpus: saved.plan.vcpus, memoryMb: saved.plan.memoryMb,
    diskMb: saved.plan.diskGb * 1024, lifecycle: "permanent" };
}
