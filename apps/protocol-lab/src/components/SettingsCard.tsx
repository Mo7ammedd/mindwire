import { useEffect, useState } from "react";
import type { DaemonClient } from "../lib/daemon";
import type { AgentInfo, Field } from "../lib/types";

/** Renders the agent's settings schema generically — the web hardcodes nothing about
 *  any agent. Each field is drawn by its `type` (select/toggle/text/secret/multiselect);
 *  the actual fields, options, and values all come from the daemon's adapter. Prefilled
 *  from GET /config, saved via PUT /config (merge), applied on the next turn. */
export function SettingsCard({ client, info, onChange }: {
  client: DaemonClient; info: AgentInfo | null; onChange?: () => void;
}) {
  const [values, setValues] = useState<Record<string, string>>({});
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);

  // Seed schema defaults into state (skipping secrets) so every shown value is also a
  // stored value — render, toggle, and save all read from one source of truth, and
  // defaulted-but-untouched fields are still sent on save. Stored config overrides defaults.
  useEffect(() => {
    let cancelled = false;
    const defaults: Record<string, string> = {};
    for (const sec of info?.schema?.sections ?? []) {
      for (const f of sec.fields) {
        if (f.type !== "secret" && f.default) defaults[f.key] = f.default;
      }
    }
    client.config()
      .then((c) => { if (!cancelled) setValues({ ...defaults, ...c }); })
      .catch(() => { if (!cancelled) setValues(defaults); });
    return () => { cancelled = true; };
  }, [client, info]);

  if (!info) return null;
  const sections = info.schema?.sections ?? [];
  if (sections.length === 0) return null;

  const set = (k: string, v: string) => { setValues((c) => ({ ...c, [k]: v })); setSaved(false); };

  const toggleMulti = (k: string, val: string) => {
    const cur = (values[k] || "").split(",").map((s) => s.trim()).filter(Boolean);
    const next = cur.includes(val) ? cur.filter((x) => x !== val) : [...cur, val];
    set(k, next.join(","));
  };

  const save = async () => {
    setSaving(true);
    try { await client.setConfig(values); setSaved(true); onChange?.(); }
    catch { /* surfaced via banner on reload */ }
    finally { setSaving(false); }
  };

  const renderField = (f: Field) => {
    // values is pre-seeded with defaults (above), so no default fallback here — secrets
    // in particular are never prefilled with a default.
    const v = values[f.key] ?? "";
    switch (f.type) {
      case "select":
        return (
          <select value={v} onChange={(e) => set(f.key, e.target.value)}>
            {(f.options || []).map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
          </select>
        );
      case "toggle":
        return (
          <label className="toggle">
            <input type="checkbox" checked={v === "true"} onChange={(e) => set(f.key, e.target.checked ? "true" : "")} />
            <span className="muted">{v === "true" ? "on" : "off"}</span>
          </label>
        );
      case "multiselect": {
        const sel = (v || "").split(",").map((s) => s.trim()).filter(Boolean);
        return (
          <div className="multi">
            {(f.options || []).map((o) => (
              <button key={o.value} type="button"
                className={"chip-btn " + (sel.includes(o.value) ? "on" : "")}
                onClick={() => toggleMulti(f.key, o.value)}>{o.label}</button>
            ))}
          </div>
        );
      }
      case "secret":
        return <input type="password" value={v} placeholder={f.placeholder} onChange={(e) => set(f.key, e.target.value)} />;
      default:
        return <input value={v} placeholder={f.placeholder} onChange={(e) => set(f.key, e.target.value)} />;
    }
  };

  return (
    <div className="card">
      <h2>Settings</h2>
      {sections.map((sec) => (
        <div key={sec.title} className="settings-section">
          <div className="settings-section-title">{sec.title}</div>
          {sec.fields.map((f) => (
            <div key={f.key} className="field">
              <label className="field-label">{f.label}{f.required ? " *" : ""}</label>
              {renderField(f)}
              {f.help && <div className="muted">{f.help}</div>}
            </div>
          ))}
        </div>
      ))}
      <div className="row" style={{ marginTop: 12 }}>
        <button className="primary" onClick={() => void save()} disabled={saving}>{saving ? "…" : "Save settings"}</button>
        {saved && <span className="muted">saved ✓ — applies to the next turn</span>}
      </div>
    </div>
  );
}
