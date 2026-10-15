import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The app talks to the daemon directly via a configurable base URL (run the daemon
// with DEV_CORS=1). No proxy needed.
export default defineConfig({
  plugins: [react()],
  server: { port: 5175 },
});
