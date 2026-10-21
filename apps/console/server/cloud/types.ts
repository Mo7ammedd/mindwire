import type { CloudComputer, ComputerPlan, ComputerState } from "../../shared/cloud";

export { OperationError as CloudError } from "../errors";
export interface ComputerContract {
  version: string;
  name?: string;
  plan: ComputerPlan;
  image: string;
  request: Record<string, unknown>;
  checkoutRequest?: Record<string, unknown>;
  checkoutStatus?: { status: "open" | "complete" | "expired"; paymentStatus: "paid" | "unpaid" | "no_payment_required"; fulfilled?: boolean; fulfillmentStatus?: string };
  cancellation?: { checkoutId: string; idempotencyKey: string; quoteId?: string };
  checkoutError?: { code: string; reference?: string; retryable: boolean };
  subscription?: { status: string; paidThrough: string | null; cancelAtPeriodEnd: boolean };
}
export interface ComputerRow extends Record<string, unknown> {
  id: string; owner_id: string; request_key: string; namespace: string; name: string;
  state: ComputerState; contract: string; workspace_id: string | null;
  checkout_id: string | null; checkout_url: string | null; error: string | null;
  lease_token: string | null; lease_until: number; created_at: number; updated_at: number;
}
export function contract(row: ComputerRow): ComputerContract { return JSON.parse(row.contract) as ComputerContract; }
export function checkoutPayable(status: NonNullable<ComputerContract["checkoutStatus"]>): boolean {
  return status.status === "open" && status.paymentStatus === "unpaid" && !status.fulfilled;
}
export function publicComputer(row: ComputerRow) {
  const saved = contract(row);
  const pending = ["draft", "checkout_pending", "payment_pending"].includes(row.state);
  const status = saved.checkoutStatus;
  const processing = status && status.status !== "expired" && !checkoutPayable(status);
  const purchase: CloudComputer["purchase"] = pending ? {
    status: processing ? "processing" : status?.status === "expired" ? "expired" : saved.cancellation ? "canceling"
      : row.state === "draft" ? "draft" : row.state === "checkout_pending" ? "recovering" : "awaiting_payment",
    canContinue: !saved.cancellation && !processing && status?.status !== "expired",
    canCancel: !processing && (row.state === "draft" || status?.status === "expired" || !!row.checkout_id),
    error: saved.checkoutError ?? null,
  } : null;
  return { id: row.id, name: row.name, plan: saved.plan, image: saved.image, state: row.state,
    workspaceId: row.workspace_id, checkout: row.checkout_id && row.checkout_url && purchase?.canContinue && status && checkoutPayable(status) && !saved.checkoutError ? { id: row.checkout_id, url: row.checkout_url } : null,
    subscription: saved.subscription ?? null, error: row.error, purchase };
}
