import { useState } from "react";
import type { DaemonClient } from "../lib/daemon";
import type { AgentInfo, AuthState } from "../lib/types";

export function AuthCard({ client, info, onChange }: { client: DaemonClient; info: AgentInfo | null; onChange: () => void }) {
  const [vals, setVals] = useState<Record<string, string>>({});
  const [state, setState] = useState<AuthState | null>(null);
  const [busy, setBusy] = useState(false);

  if (!info) return null;

  const submitField = async (method: string, key: string) => {
    setBusy(true);
    try {
      await client.authBegin(method);
      const st = await client.authStep({ [key]: vals[method] || "" });
      setState(st);
      onChange();
    } catch (e) {
      setState({ method, status: "error", message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  const beginLogin = async (method: string) => {
    setBusy(true);
    try {
      const st = await client.authBegin(method);
      setState(st);
      if (st.url) window.open(st.url, "_blank");
      const timer = setInterval(async () => {
        try {
          const s = await client.authStatus();
          if (s.configured) {
            clearInterval(timer);
            setState({ method, status: "complete" });
            onChange();
          }
        } catch { /* keep polling */ }
      }, 2500);
      setTimeout(() => clearInterval(timer), 10 * 60 * 1000);
    } catch (e) {
      setState({ method, status: "error", message: (e as Error).message });
    } finally {
      setBusy(false);
    }
  };

  const st = info.authStatus;
  return (
    <div className="card">
      <h2>Auth</h2>
      <div className="status">
        {st.configured
          ? <span><span className="dot ok" />authenticated via {st.method}</span>
          : <span><span className="dot warn" />not authenticated</span>}
      </div>

      {info.authMethods.map((m) => (
        <div key={m.id} className="authrow">
          {m.interactive ? (
            <>
              <button onClick={() => void beginLogin(m.id)} disabled={busy}>{m.label}</button>
              <span className="muted">{m.help}</span>
            </>
          ) : (
            <>
              <input
                className="grow"
                type={m.fields?.[0]?.type === "secret" ? "password" : "text"}
                placeholder={m.fields?.[0]?.placeholder || m.label}
                value={vals[m.id] || ""}
                onChange={(e) => setVals({ ...vals, [m.id]: e.target.value })}
              />
              <button className="primary" onClick={() => void submitField(m.id, m.fields?.[0]?.key || "")} disabled={busy}>
                Save
              </button>
            </>
          )}
        </div>
      ))}

      {state && (
        <div className="muted" style={{ marginTop: 8 }}>
          {state.status}
          {state.url ? <> · <a href={state.url} target="_blank" rel="noreferrer">open URL</a></> : null}
          {state.message ? " — " + state.message : ""}
        </div>
      )}
    </div>
  );
}
