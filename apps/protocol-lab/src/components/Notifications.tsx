import { useEffect, useRef, useState } from "react";
import type { DaemonClient } from "../lib/daemon";
import type { Notification } from "../lib/types";

const ICON: Record<string, string> = {
  finished: "✅", error: "⚠️", waiting_approval: "✋", waiting_feedback: "💬", waiting_input: "⌨️",
};

function Body({ n, onAction }: { n: Notification; onAction?: (id: string) => void }) {
  return (
    <>
      <span className="notif-ico">{ICON[n.condition] || "🔔"}</span>
      <div className="notif-main">
        <div className="notif-title">{n.title}</div>
        {n.body && <div className="muted">{n.body}</div>}
        {n.actions && n.actions.length > 0 && (
          <div className="notif-actions">
            {n.actions.map((a) => (
              <button key={a.id} className="chip-btn" onClick={(e) => { e.stopPropagation(); onAction?.(a.id); }}>{a.label}</button>
            ))}
          </div>
        )}
      </div>
    </>
  );
}

/** Subscribes to the daemon's live notification feed: a recent list + transient toasts.
 *  Notifications are real — emitted when the agent finishes, errors, or needs you. */
export function Notifications({ client }: { client: DaemonClient }) {
  const [recent, setRecent] = useState<Notification[]>([]);
  const [toasts, setToasts] = useState<{ id: number; n: Notification }[]>([]);
  const idRef = useRef(0);

  useEffect(() => {
    const ctrl = new AbortController();
    const push = (n: Notification) => {
      setRecent((r) => [n, ...r].slice(0, 30));
      const id = ++idRef.current;
      setToasts((t) => [...t, { id, n }]);
      window.setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), 8000);
    };
    client.streamNotifications(push, ctrl.signal).catch(() => { /* aborted, or daemon down */ });
    return () => ctrl.abort();
  }, [client]);

  const dismiss = (id: number) => setToasts((t) => t.filter((x) => x.id !== id));

  return (
    <>
      <div className="card">
        <h2>Notifications</h2>
        <div className="notif-list">
          {recent.length === 0
            ? <div className="muted">No notifications yet — they appear when the agent finishes, errors, or needs you.</div>
            : recent.map((n, i) => <div key={i} className={"notif c-" + n.condition}><Body n={n} /></div>)}
        </div>
      </div>

      <div className="toast-stack">
        {toasts.map(({ id, n }) => (
          <div key={id} className={"toast c-" + n.condition} onClick={() => dismiss(id)} title="click to dismiss">
            <Body n={n} onAction={() => dismiss(id)} />
          </div>
        ))}
      </div>
    </>
  );
}
