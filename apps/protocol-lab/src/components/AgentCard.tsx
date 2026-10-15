import type { AgentInfo } from "../lib/types";

export function AgentCard({ info }: { info: AgentInfo | null }) {
  if (!info) {
    return (
      <div className="card">
        <h2>Agent</h2>
        <div className="muted">Not connected. Set the daemon URL and press Connect.</div>
      </div>
    );
  }
  const caps = info.capabilities as unknown as Record<string, unknown>;
  return (
    <div className="card">
      <h2>Agent</h2>
      <div className="kv"><span>name</span><b>{info.name} ({info.agentType})</b></div>
      <div className="kv"><span>daemon</span><b>{info.version}</b></div>
      <div className="kv"><span>installed CLI</span><b>{info.installedVersion || "—"}</b></div>
      <div className="kv"><span>configured</span><b>{info.configured ? "yes" : "no"}</b></div>

      <h2 style={{ marginTop: 14 }}>Capabilities</h2>
      <div className="chips">
        {Object.entries(caps).map(([k, v]) => (
          <span key={k} className={"chip " + (v && v !== "none" ? "on" : "")}>{k}: {String(v)}</span>
        ))}
      </div>
    </div>
  );
}
