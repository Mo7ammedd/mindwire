import type { BillingOffer } from "./provider";
import { COMPUTER_PLANS, computerPlanFitsImage } from "../../shared/cloud";
import { env } from "../env";
import { CloudProvider } from "./provider";
import { ComputerStore } from "./store";
import { CloudError, checkoutPayable, contract, type ComputerRow } from "./types";
import { monthlyComputerImage } from "./images";
import { CheckoutProviderError } from "./provider-errors";

export class ComputerService {
  constructor(readonly store = new ComputerStore(), readonly provider = new CloudProvider()) {}

  async create(owner: string, input: { idempotencyKey: string; name: string; planId: string; imageId: string }) {
    const plan = COMPUTER_PLANS.find(p => p.id === input.planId);
    if (!plan || !/^[A-Za-z0-9_-]{16,128}$/.test(input.idempotencyKey) || !input.name.trim() || input.name.length > 100 || input.imageId.length > 128)
      throw new CloudError(400, "invalid_computer", "Choose a monthly plan, computer name and supported image.");
    // Validate the provider's catalog before opening payment. No unpriced Mac/GPU
    // hardware, arbitrary namespace, extra VM or hidden config can enter checkout.
    const images = await this.provider.master().workspaces.images.list();
    const image = images.images.find(entry => entry.id === input.imageId);
    if (!image || !monthlyComputerImage(image))
      throw new CloudError(400, "unsupported_image", "Choose a supported Cloud Computer image.");
    if (!computerPlanFitsImage(plan, image))
      throw new CloudError(400, "computer_too_small", "Choose a larger monthly computer for this image.");
    const request = { image: image.image, ...(image.preset ? { preset: image.preset } : {}), mode: "permanent", cpus: plan.vcpus, memory_mb: plan.memoryMb,
      disk_size_mb: plan.diskGb * 1024, config: { ...image.vm_defaults } };
    return this.store.create(owner, input.idempotencyKey, input.name.trim(), plan, image.image, request);
  }

  async checkout(owner: string, id: string, customer: { email: string; name?: string }) {
    return this.store.locked(owner, id, async (row, save) => {
      if (!["draft", "checkout_pending", "payment_pending"].includes(row.state)) return row;
      const fresh = row.state === "draft";
      const saved = contract(row);
      if (saved.checkoutStatus?.status === "expired")
        throw new CloudError(409, "checkout_expired", "This checkout expired. Cancel this purchase to choose a new computer.");
      if (saved.cancellation)
        throw new CloudError(409, "checkout_cancellation_pending", "Cancellation is still being confirmed. Refresh this purchase.");
      if (row.checkout_id) {
        saved.checkoutStatus = await this.provider.checkoutStatus(row.namespace, row.checkout_id);
        delete saved.checkoutError;
        row.contract = JSON.stringify(saved); row.error = null; await save(row);
        if (!checkoutPayable(saved.checkoutStatus)) return row;
      }
      if (!saved.checkoutRequest) {
        if (!fresh) throw new CloudError(409, "contract_missing", "This purchase needs support to recover its original checkout request.");
        const offer = await this.provider.offer(saved.plan, saved.version);
        await this.provider.ensureNamespace(row.namespace, row.name);
        saved.checkoutRequest = { namespace: row.namespace, kind: "subscription", offer,
          billingInterval: "monthly", allowPromotionCodes: true, idempotencyKey: `mindwire-computer:${row.id}:checkout:v1`,
          customer, metadata: { product: "mindwire-computer", computer: row.id },
          successUrl: new URL(`/computers?computer=${encodeURIComponent(row.id)}`, env.baseUrl).href,
          cancelUrl: new URL(`/computers?computer=${encodeURIComponent(row.id)}`, env.baseUrl).href };
        row.contract = JSON.stringify(saved);
      }
      row.state = "checkout_pending";
      // Persist the exact provider request BEFORE dispatch. A timeout is an
      // uncertain result, never permission to start another subscription.
      await save(row);
      let checkout;
      try { checkout = await this.provider.checkout(saved.checkoutRequest); }
      catch (error) {
        if (error instanceof CheckoutProviderError) {
          // As in OpenShip, a documented rejection releases only a first
          // attempt. A previously uncertain charge must remain recoverable.
          if (fresh && error.checkoutRejected) row.state = "draft";
          if (error.checkoutExpired) saved.checkoutStatus = { status: "expired", paymentStatus: "unpaid" };
          row.contract = JSON.stringify(saved);
          await save(row);
        }
        throw error;
      }
      if (row.checkout_id && row.checkout_id !== checkout.checkoutId)
        throw new CloudError(502, "cloud_scope_mismatch", "Cloud returned a different checkout for this purchase. Refresh its payment status.");
      delete saved.checkoutError;
      row.contract = JSON.stringify(saved);
      row.checkout_id = checkout.checkoutId; row.checkout_url = checkout.url;
      row.state = "payment_pending"; row.error = null;
      // Preserve the recovered identity even if the following status read fails.
      await save(row);
      saved.checkoutStatus = await this.provider.checkoutStatus(row.namespace, checkout.checkoutId);
      row.contract = JSON.stringify(saved); await save(row);
      return row;
    });
  }

  /** Used by browser polling, native polling and background reconciliation alike. */
  async reconcile(owner: string, id: string): Promise<ComputerRow> {
    const before = await this.store.get(owner, id);
    const previous = contract(before);
    if (previous.checkoutStatus?.status === "expired") return before;
    // Like OpenShip's listing, automatic recovery never replays an unknown
    // checkout creation. Only explicit Continue checkout resumes that request.
    if (before.state === "checkout_pending" && !before.checkout_id) return before;
    return this.store.locked(owner, id, async (row, save) => {
      if (["draft", "deleting", "deleted"].includes(row.state)) return row;
      const saved = contract(row), offer = saved.checkoutRequest?.offer as BillingOffer | undefined;
      if (!offer) throw new CloudError(409, "contract_missing", "This computer needs support to recover its saved subscription.");
      if (["payment_pending", "checkout_pending"].includes(row.state)) {
        if (!row.checkout_id) throw new CloudError(409, "contract_missing", "This purchase needs its original payment record recovered.");
        const status = await this.provider.checkoutStatus(row.namespace, row.checkout_id);
        saved.checkoutStatus = status;
        delete saved.checkoutError;
        if (saved.cancellation && status.status === "expired") {
          row.state = "deleted"; row.checkout_url = null; delete saved.cancellation;
        } else {
          row.state = "payment_pending";
          if (!checkoutPayable(status)) delete saved.cancellation;
        }
        row.contract = JSON.stringify(saved);
        row.error = status.status === "expired" && row.state !== "deleted" ? "This checkout expired. Cancel this purchase to choose a new computer." : null;
        await save(row);
        if (status.status === "expired" || checkoutPayable(status) || status.paymentStatus === "unpaid") return row;
      }
      const confirmed = await this.provider.paid(row.namespace, offer);
      if (confirmed.subscription) saved.subscription = confirmed.subscription;
      delete saved.checkoutError;
      row.contract = JSON.stringify(saved); row.error = null; await save(row);
      if (!confirmed.paid) return row;
      if (row.workspace_id) {
        if (row.state === "provisioning") {
          const workspace = await (await this.provider.scoped(row.namespace)).workspaces.get(row.workspace_id);
          if (workspace.ready) { row.state = "ready"; await save(row); }
        }
        return row;
      }
      row.state = "paid"; row.error = null; await save(row);
      // Creation retries always reuse the same provider key, including a lost
      // reply or a replica taking over after a process crash.
      const workspace = await this.provider.provision(row.namespace, { ...saved.request, name: row.name, idempotency_key: `mindwire-computer:${row.id}:create:v1` });
      if (!workspace.id || workspace.namespace !== row.namespace)
        throw new CloudError(502, "cloud_scope_mismatch", "Cloud returned a different computer.");
      row.workspace_id = workspace.id; row.state = workspace.ready ? "ready" : "provisioning";
      await save(row);
      return row;
    });
  }

  async cancelCheckout(owner: string, id: string) {
    return this.store.locked(owner, id, async (row, save) => {
      const saved = contract(row);
      const close = async () => {
        row.state = "deleted"; row.checkout_url = null; row.error = null;
        delete saved.cancellation;
        delete saved.checkoutError;
        row.contract = JSON.stringify(saved);
        await save(row); return row;
      };
      if (row.state === "deleted") return row;
      if (row.state === "draft") return close();
      if (row.state === "checkout_pending" && !row.checkout_id) {
        // An explicit expiry is terminal even when the checkout ID was lost.
        if (saved.checkoutStatus?.status === "expired") return close();
        throw new CloudError(409, "checkout_unconfirmed", "Resume checkout to confirm this payment before canceling it.");
      }
      if (!["payment_pending", "checkout_pending"].includes(row.state) || !row.checkout_id)
        throw new CloudError(409, "checkout_pending", "Check the saved checkout before starting another purchase.");
      const before = await this.provider.checkoutStatus(row.namespace, row.checkout_id);
      saved.checkoutStatus = before;
      delete saved.checkoutError;
      row.error = null;
      const settled = async () => {
        if (saved.checkoutStatus?.status === "expired") return close();
        if (saved.checkoutStatus && !checkoutPayable(saved.checkoutStatus)) {
          delete saved.cancellation;
          delete saved.checkoutError;
          row.state = "payment_pending"; row.error = null;
          row.contract = JSON.stringify(saved); await save(row);
          return row;
        }
      };
      const closed = await settled();
      if (closed) return closed;
      if (!saved.cancellation)
        saved.cancellation = await this.provider.checkoutCancellation(row.namespace, row.checkout_id, `mindwire-computer:${row.id}:cancel-checkout`);
      if (saved.cancellation.checkoutId !== row.checkout_id)
        throw new CloudError(409, "cloud_scope_mismatch", "The saved cancellation does not match this payment. Contact Mindwire support.");
      row.contract = JSON.stringify(saved); await save(row);
      let failure: unknown;
      try {
        const cancellation = saved.cancellation;
        if (cancellation.quoteId) await this.provider.cancelCapacityCheckout(row.namespace, cancellation.quoteId, cancellation.idempotencyKey);
        else await this.provider.cancelCheckout(row.namespace, row.checkout_id, cancellation.idempotencyKey);
      }
      catch (error) { failure = error; }
      // A lost cancellation reply or concurrent payment is resolved by reading
      // this exact checkout, not by treating a network error as a failed charge.
      saved.checkoutStatus = await this.provider.checkoutStatus(row.namespace, row.checkout_id);
      row.contract = JSON.stringify(saved); await save(row);
      const finished = await settled();
      if (finished) return finished;
      if (failure) throw failure;
      return row;
    });
  }

  async subscription(owner: string, id: string, action: "cancel" | "resume") {
    return this.store.locked(owner, id, async (row, save) => {
      if (["deleted", "deleting", "draft", "checkout_pending", "payment_pending"].includes(row.state))
        throw new CloudError(409, "subscription_unavailable", "This computer does not have an active monthly subscription.");
      const billing = this.provider.master().billing;
      const result = action === "cancel" ? await billing.cancelSubscription(row.namespace) : await billing.resumeSubscription(row.namespace);
      if (result.namespace !== row.namespace || !result.subscription)
        throw new CloudError(502, "cloud_scope_mismatch", "Cloud returned a different computer subscription.");
      const saved = contract(row), s = result.subscription;
      saved.subscription = { status: s.status, paidThrough: s.periodEnd, cancelAtPeriodEnd: s.cancelAtPeriodEnd };
      delete saved.checkoutError;
      row.contract = JSON.stringify(saved); row.error = null; await save(row); return row;
    });
  }
}
