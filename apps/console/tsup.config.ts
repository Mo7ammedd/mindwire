import { defineConfig } from "tsup";

// Bundle the hosted account API; dependencies resolve from the source deployment install.
export default defineConfig({
  entry: { index: "server/index.ts", "import-push": "scripts/import-push.ts" },
  outDir: "dist-server",
  format: ["esm"],
  platform: "node",
  target: "node24",
  clean: true,
  sourcemap: true,
  // Keep the provider client external. No agent runtime is loaded by Console.
  external: ["oblien"],
  // Keep native/runtime imports as authored; the Node server resolves external dependencies from its
  // workspace install in the production image.
  removeNodeProtocol: false,
});
