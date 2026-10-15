import { useState } from "react";
import type { DaemonClient } from "../lib/daemon";
import type { SetupResult } from "../lib/types";

export function SetupCard({ client, onChange }: { client: DaemonClient; onChange: () => void }) {
  const [out, setOut] = useState<SetupResult | null>(null);
  const [busy, setBusy] = useState(false);

  const run = async (force: boolean) => {
    setBusy(true);
    try {
      setOut(await client.setup(force));
      onChange();
    } catch (e) {
      setOut({ ok: false, steps: [{ name: "error", status: (e as Error).message }] });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="card">
      <h2>Toolchain</h2>
      <div className="row">
        <button onClick={() => void run(false)} disabled={busy}>Setup (ensure)</button>
        <button onClick={() => void run(true)} disabled={busy}>Update (force)</button>
      </div>
      {out && (
        <div style={{ marginTop: 8 }}>
          {out.steps.map((s, i) => (
            <div key={i} className="kv"><span>{s.name}</span><b>{s.status}</b></div>
          ))}
          <div className="muted">ok: {String(out.ok)}</div>
        </div>
      )}
    </div>
  );
}
