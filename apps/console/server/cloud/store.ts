import { createHash, randomUUID } from "node:crypto";
import { sql } from "drizzle-orm";
import { consoleRows, postgres } from "../database";
import { COMPUTER_CATALOG_VERSION, type ComputerPlan } from "../../shared/cloud";
import { CloudError, contract, type ComputerRow } from "./types";
import { operationFailure } from "../errors";
import { requireActiveAccount } from "../account/deletion-state";

export class ComputerStore {
  constructor(private readonly deletingAccount = false) {}
  async list(owner: string): Promise<ComputerRow[]> {
    return consoleRows<ComputerRow>(sql`SELECT * FROM cloud_computer WHERE owner_id=${owner} AND state<>'deleted' ORDER BY created_at DESC`);
  }
  async get(owner: string, id: string): Promise<ComputerRow> {
    const row = (await consoleRows<ComputerRow>(sql`SELECT * FROM cloud_computer WHERE owner_id=${owner} AND id=${id}`))[0];
    if (!row) throw new CloudError(404, "computer_not_found", "Cloud Computer not found.");
    return row;
  }
  async byWorkspace(owner: string, id: string): Promise<ComputerRow> {
    const row = (await consoleRows<ComputerRow>(sql`SELECT * FROM cloud_computer WHERE owner_id=${owner} AND workspace_id=${id} AND state<>'deleted'`))[0];
    if (!row) throw new CloudError(404, "computer_not_found", "Cloud Computer not found.");
    return row;
  }
  async create(owner: string, key: string, name: string, plan: ComputerPlan, image: string, request: Record<string, unknown>): Promise<ComputerRow> {
    const id = `computer_${randomUUID().replaceAll("-", "")}`;
    const namespace = `mw-c-${createHash("sha256").update(id).digest("hex").slice(0, 40)}`;
    const now = Date.now();
    const saved = JSON.stringify({ version: COMPUTER_CATALOG_VERSION, name, plan, image, request });
    const insertion = sql`INSERT INTO cloud_computer(id,owner_id,request_key,namespace,name,contract,created_at,updated_at)
      SELECT ${id},${owner},${key},${namespace},${name},${saved},${now},${now}
      WHERE (SELECT count(*) FROM cloud_computer WHERE owner_id=${owner} AND state IN ('draft','checkout_pending','payment_pending'))<10
      AND EXISTS (SELECT 1 FROM "user" WHERE id=${owner})
      AND NOT EXISTS (SELECT 1 FROM account_deletion WHERE owner_id=${owner})
      ON CONFLICT(owner_id,request_key) DO NOTHING RETURNING id`;
    if (postgres) await postgres.transaction(async tx => {
      await tx.execute(sql`SELECT id FROM "user" WHERE id=${owner} FOR UPDATE`);
      await tx.execute(insertion);
    });
    else await consoleRows(insertion);
    const row = (await consoleRows<ComputerRow>(sql`SELECT * FROM cloud_computer WHERE owner_id=${owner} AND request_key=${key}`))[0];
    if (!row) throw new CloudError(429, "pending_purchase_limit", "Finish or cancel an existing computer purchase before starting another.");
    const previous = contract(row);
    if ((previous.name ?? row.name) !== name || previous.plan.id !== plan.id || previous.image !== image || JSON.stringify(previous.request) !== JSON.stringify(request))
      throw new CloudError(409, "idempotency_conflict", "This request already belongs to a different computer. Start a new purchase.");
    return row;
  }
  /** Cross-replica lease with fencing. External calls also use stable idempotency keys. */
  async locked<T>(owner: string, id: string, work: (row: ComputerRow, save: (next: ComputerRow) => Promise<void>) => Promise<T>): Promise<T> {
    if (!this.deletingAccount) await requireActiveAccount(owner);
    const token = randomUUID(), now = Date.now();
    const row = (await consoleRows<ComputerRow>(sql`UPDATE cloud_computer SET lease_token=${token},lease_until=${now + 120000}
      WHERE id=${id} AND owner_id=${owner} AND lease_until<${now} RETURNING *`))[0];
    if (!row) {
      await this.get(owner, id);
      throw new CloudError(409, "computer_busy", "This computer is finishing another operation. Retry shortly.");
    }
    const save = async (next: ComputerRow) => {
      const written = await consoleRows(sql`UPDATE cloud_computer SET state=${next.state},contract=${next.contract},workspace_id=${next.workspace_id},
        checkout_id=${next.checkout_id},checkout_url=${next.checkout_url},error=${next.error},updated_at=${Date.now()}
        WHERE id=${id} AND owner_id=${owner} AND lease_token=${token} AND lease_until>${Date.now()} RETURNING id`);
      if (!written.length) throw new CloudError(409, "computer_busy", "Computer recovery has taken over this operation. Refresh its status.");
    };
    try { return await work(row, save); }
    catch (error) {
      const failure = operationFailure(error);
      const message = failure.message;
      const saved = contract(row);
      saved.checkoutError = { code: failure.code,
        retryable: failure.details?.retryable ?? (failure.status >= 500 || failure.status === 429 || failure.code === "computer_busy"),
        ...(failure.details?.reference ? { reference: failure.details.reference } : {}) };
      await consoleRows(sql`UPDATE cloud_computer SET error=${message},contract=${JSON.stringify(saved)},updated_at=${Date.now()}
        WHERE id=${id} AND owner_id=${owner} AND lease_token=${token} AND lease_until>${Date.now()} RETURNING id`);
      throw failure;
    }
    finally { await consoleRows(sql`UPDATE cloud_computer SET lease_token=NULL,lease_until=0 WHERE id=${id} AND owner_id=${owner} AND lease_token=${token} RETURNING id`); }
  }
}
