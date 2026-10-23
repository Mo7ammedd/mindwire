import { sql } from "drizzle-orm";
import { consoleRows } from "../database";
import { OperationError } from "../errors";

/** Kept independent of auth and Cloud to avoid circular identity dependencies. */
export async function accountDeletionPending(owner: string): Promise<boolean> {
  return (await consoleRows(sql`SELECT id FROM account_deletion WHERE owner_id=${owner} AND status='pending'`)).length > 0;
}

export async function requireActiveAccount(owner: string): Promise<void> {
  if (await accountDeletionPending(owner))
    throw new OperationError(409, "account_deletion_pending", "Your account is being deleted. You can check progress in Account settings.");
}
