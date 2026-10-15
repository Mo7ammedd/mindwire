import { spawnSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

const directory = fileURLToPath(new URL("../packages/daemon/", import.meta.url));
mkdirSync(new URL("../packages/daemon/.dev/", import.meta.url), { recursive: true });
const binary = process.platform === "win32" ? ".dev/mindwired.exe" : ".dev/mindwired";
const result = spawnSync("go", ["build", "-trimpath", "-o", binary, "./cmd/daemon"], {
  cwd: directory,
  stdio: "inherit",
});
if (result.error) console.error(result.error.message);
process.exit(result.status ?? 1);
