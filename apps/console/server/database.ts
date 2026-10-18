// Console persistence boundary. Better Auth receives `authDatabase` (its supported native adapter),
// while Console-owned data uses the typed Drizzle clients below. Keeping driver construction here makes
// Postgres and better-sqlite3 deployment modes an implementation detail of repositories.
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import Database from "better-sqlite3";
import { Pool } from "pg";
import { drizzle as drizzlePg } from "drizzle-orm/node-postgres";
import { drizzle as drizzleSqlite } from "drizzle-orm/better-sqlite3";
import { migrate as migratePg } from "drizzle-orm/node-postgres/migrator";
import { migrate as migrateSqlite } from "drizzle-orm/better-sqlite3/migrator";
import type { SQL } from "drizzle-orm";

import { env } from "./env";

export const authDatabase = env.databaseUrl
  ? new Pool({ connectionString: env.databaseUrl })
  : (mkdirSync(dirname(env.authDbPath), { recursive: true }), new Database(env.authDbPath));

export const postgres = authDatabase instanceof Pool ? drizzlePg({ client: authDatabase }) : undefined;
export const sqlite = authDatabase instanceof Database ? drizzleSqlite({ client: authDatabase }) : undefined;

/** Bound Console queries shared by its repositories in both deployment modes. */
export async function consoleRows<T extends Record<string, unknown>>(query: SQL): Promise<T[]> {
  if (postgres) return (await postgres.execute<T>(query)).rows as T[];
  return sqlite!.all<T>(query);
}

/** Apply checked-in Console migrations before the server accepts traffic. */
export async function migrateConsoleDatabase(): Promise<void> {
  if (postgres) {
    await migratePg(postgres, { migrationsFolder: fileURLToPath(new URL("../drizzle/pg", import.meta.url)) });
  } else {
    migrateSqlite(sqlite!, { migrationsFolder: fileURLToPath(new URL("../drizzle/sqlite", import.meta.url)) });
  }
}

/** Small local write transactions; no network work may run inside them. SQLite's
 * callback remains synchronous, while PostgreSQL executes the same bound SQL. */
export async function consoleWriteBatch(queries: SQL[], locks: SQL[] = []): Promise<Record<string, unknown>[][]> {
  if (postgres) return postgres.transaction(async tx => {
    for (const query of locks) await tx.execute(query);
    const results: Record<string, unknown>[][] = [];
    for (const query of queries) results.push((await tx.execute(query)).rows);
    return results;
  });
  return sqlite!.transaction(tx => queries.map(query => tx.all<Record<string, unknown>>(query)), { behavior: "immediate" });
}
