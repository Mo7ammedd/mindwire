import { useEffect, useState } from "react";
import type { DaemonClient } from "../lib/daemon";
import type { DoctorReport } from "../lib/types";

const DOT: Record<string, string> = { ok: "ok", warn: "warn", fail: "err" };

/** Health report: generic daemon checks (workspace, auth) + the active agent's own
 *  checks (CLI installed/version, toolchain), served by GET /doctor. */
export function DoctorCard({ client }: { client: DaemonClient }) {
  const [report, setReport] = useState<DoctorReport | null>(null);
  const [busy, setBusy] = useState(false);

  const run = async () => {
    setBusy(true);
    try { setReport(await client.doctor()); } catch { setReport(null); } finally { setBusy(false); }
  };
  useEffect(() => { void run(); }, [client]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <div className="card">
      <h2>Doctor</h2>
      <div className="row" style={{ marginBottom: 8 }}>
        <button onClick={() => void run()} disabled={busy}>{busy ? "…" : "Run checks"}</button>
        {report && <span className="muted">{report.ok ? "all good ✓" : "issues found"}</span>}
      </div>
      {report
        ? report.checks.map((c, i) => (
            <div className="kv" key={i}>
              <span><span className={"dot " + (DOT[c.status] || "")} />{c.name}</span>
              <b style={{ fontWeight: 400, color: "var(--dim)" }}>{c.detail || c.status}</b>
            </div>
          ))
        : !busy && <div className="muted">Not connected.</div>}
    </div>
  );
}
