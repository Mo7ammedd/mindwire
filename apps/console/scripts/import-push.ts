import { readFile } from "node:fs/promises";
import { Pool } from "pg";
import { authDatabase } from "../server/database";
import { importPushData } from "../server/notifications/import";

// Preview by default. Run only after the new Console migrations have completed
// and the old notification endpoints are paused; see the migration runbook.
const args = process.argv.slice(2), file = args.find(arg => !arg.startsWith("--"));
if (!file || args.some(arg => arg.startsWith("--") && arg !== "--apply")) throw new Error("Usage: import-push <snapshot.json> [--apply]");
if (!(authDatabase instanceof Pool)) throw new Error("The legacy Cloud push import requires PostgreSQL");
try {
  console.log(JSON.stringify(await importPushData(JSON.parse(await readFile(file, "utf8")), authDatabase, args.includes("--apply")), null, 2));
} finally { await authDatabase.end(); }
