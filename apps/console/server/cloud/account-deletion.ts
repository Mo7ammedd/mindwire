import { ComputerService } from "./service";
import { ComputerStore } from "./store";
import { CloudError, contract } from "./types";
import type { BillingOffer } from "./provider";

/** Uses the same fenced computer operations and saved checkout identities as the
 * ordinary Cloud flow. Each pass removes at most one resource, then confirms it
 * through the next inventory read. A provider outage never discards ownership. */
export class AccountComputerCleanup {
  private readonly service = new ComputerService(new ComputerStore(true));

  async remove(owner: string, id: string): Promise<boolean> {
    const service = this.service;
    let row = await service.store.get(owner, id);
    if (["draft", "checkout_pending", "payment_pending"].includes(row.state)) {
      // Recover a lost reply using the exact original idempotent request. Never
      // invent a replacement checkout or assume a timed-out payment failed.
      if (row.state === "checkout_pending" && !row.checkout_id && contract(row).checkoutStatus?.status !== "expired")
        row = await service.checkout(owner, id, { email: "" });
      row = await service.cancelCheckout(owner, id);
      if (row.state !== "deleted") {
        const saved = contract(row);
        const offer = saved.checkoutRequest?.offer as BillingOffer | undefined;
        if (!offer) throw new CloudError(409, "contract_missing", "Cloud billing needs its saved checkout request.");
        const paid = await service.provider.paid(row.namespace, offer);
        if (!paid.paid) return false;
        row = await service.store.locked(owner, id, async (current, save) => {
          const value = contract(current);
          if (paid.subscription) value.subscription = paid.subscription;
          current.contract = JSON.stringify(value);
          current.state = "paid";
          await save(current);
          return current;
        });
      }
    }
    return service.store.locked(owner, id, async (current, save) => {
      const saved = contract(current);
      // A completely local draft never created a provider namespace or charge.
      if (!saved.checkoutRequest && !current.workspace_id) return true;
      if (current.state !== "deleting") {
        const result = await service.provider.master().billing.subscription(current.namespace);
        if (result.namespace !== current.namespace)
          throw new CloudError(502, "cloud_scope_mismatch", "Cloud returned a different subscription.");
        let subscription = result.subscription;
        if (!subscription && !["draft", "deleted"].includes(current.state))
          throw new CloudError(503, "cancel_unconfirmed", "Cloud billing is still being confirmed.");
        if (subscription && !subscription.cancelAtPeriodEnd && subscription.status !== "canceled") {
          const stopped = await service.provider.master().billing.cancelSubscription(current.namespace);
          if (stopped.namespace !== current.namespace || !stopped.subscription ||
              !(stopped.subscription.cancelAtPeriodEnd || stopped.subscription.status === "canceled"))
            throw new CloudError(503, "cancel_unconfirmed", "Cloud renewal could not be stopped yet.");
          subscription = stopped.subscription;
        }
        if (subscription) saved.subscription = { status: subscription.status,
          paidThrough: subscription.periodEnd, cancelAtPeriodEnd: subscription.cancelAtPeriodEnd };
        current.contract = JSON.stringify(saved);
        current.state = "deleting";
        await save(current);
      }
      let namespace;
      try { namespace = (await service.provider.master().namespaces.get(current.namespace)).data; }
      catch (error) {
        if (!(error instanceof CloudError) || error.status !== 404) throw error;
        return true;
      }
      if (namespace.slug !== current.namespace)
        throw new CloudError(502, "cloud_scope_mismatch", "Cloud returned a different computer namespace.");
      const client = await service.provider.scoped(current.namespace);
      const pages = (await client.pages.list()).pages.filter(page => page.namespace === current.namespace);
      if (pages[0]) { await client.pages.delete(pages[0].slug); return false; }
      const inventory = await client.workspaces.list({ limit: 100, page: 1 });
      if (inventory.workspaces.some(computer => computer.namespace !== current.namespace))
        throw new CloudError(502, "cloud_scope_mismatch", "Cloud returned computers from a different namespace.");
      const computers = inventory.workspaces.filter(computer => computer.namespace === current.namespace);
      if (computers[0]) { await client.workspaces.delete(computers[0].id); return false; }
      const disks = (await client.disks.list({ namespace: current.namespace })).filter(disk => disk.namespace === current.namespace);
      if (disks[0]) {
        await client.disks.delete(disks[0].id, { idempotency_key: `mindwire-account-delete:${id}:${disks[0].id}`, wait_ready: false });
        return false;
      }
      // The provider retains the canceled subscription's accounting record until
      // its paid period closes. Remove the customer-chosen computer name now;
      // never delete that record before cancellation has been confirmed.
      await service.provider.master().namespaces.update(namespace.id, { name: "Deleted Mindwire account", description: "", tags: [], metadata: {} });
      current.state = "deleted"; current.checkout_url = null;
      await save(current);
      return true;
    });
  }
}
