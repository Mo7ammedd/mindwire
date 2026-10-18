import { describe, expect, test } from "bun:test";
import { createRequire } from "node:module";
import { existsSync } from "node:fs";
import { version } from "../../package.json";

/** Exercises the public default without a Mindwire image or preinstalled daemon. */
describe.skipIf(!process.env.RUN_DOCKER_E2E)("e2e: released binary in the default Docker base", () => {
  test("installs into a plain container and exposes only authenticated loopback access", async () => {
    const binary = process.env.MINDWIRE_LINUX_DAEMON ?? process.env.MINDWIRE_DAEMON ?? "";
    if (!existsSync(binary)) throw new Error("Set MINDWIRE_LINUX_DAEMON to the Linux E2E binary.");
    const Docker = createRequire(import.meta.url)("dockerode");
    const engine = new Docker();
    const { provisionDocker } = await import("../../dist/index.js");
    const handle = await provisionDocker(engine, { daemonBin: binary, stopOnExit: true });
    try {
      const info = await engine.getContainer(handle.id).inspect();
      expect(info.Config.Image).toBe("node:24-bookworm");
      expect(info.Config.Cmd).toEqual(["sleep", "infinity"]);
      expect(info.NetworkSettings.Ports["8790/tcp"][0].HostIp).toBe("127.0.0.1");
      const healthy = await fetch(handle.baseUrl + "/healthz", { headers: { Authorization: `Bearer ${handle.token}` } });
      expect(healthy.status).toBe(200);
      expect(await healthy.json()).toMatchObject({ ok: true, version });
      expect((await fetch(handle.baseUrl + "/healthz")).status).toBe(401);
    } finally { await handle.stop(); }
  }, 300_000);
});
