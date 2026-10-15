import { useEffect, useRef, useState, type KeyboardEvent } from "react";
import type { DaemonClient } from "../lib/daemon";
import type { AgentEvent, AgentInfo, Interaction } from "../lib/types";

type Bubble = { role: "user" | "assistant" | "tool" | "thinking"; text: string; interaction?: Interaction };

export function Chat({
  client, info, chatId, onActivity,
}: {
  client: DaemonClient;
  info: AgentInfo | null;
  chatId: string;
  onActivity?: () => void;
}) {
  const [bubbles, setBubbles] = useState<Bubble[]>([]);
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);
  const [runId, setRunId] = useState<string | null>(null);
  const [log, setLog] = useState<string[]>([]);
  const threadRef = useRef<HTMLDivElement>(null);

  // Load this chat's recorded history when the active chat changes.
  useEffect(() => {
    let cancelled = false;
    setBubbles([]);
    setLog([]);
    client.messages(chatId)
      .then((ms) => { if (!cancelled) setBubbles(ms.map((m) => ({ role: m.role as Bubble["role"], text: m.text }))); })
      .catch(() => { /* new/empty chat */ });
    return () => { cancelled = true; };
  }, [chatId, client]);

  useEffect(() => { threadRef.current?.scrollTo(0, 1e9); }, [bubbles]);

  const addLog = (s: string) => setLog((l) => [...l.slice(-300), s]);

  const runTurn = async (text: string) => {
    if (!text || busy) return;
    setBubbles((b) => [...b, { role: "user", text }]);
    setBusy(true);

    let assistantIdx = -1;
    let thinkingIdx = -1;
    try {
      const run = await client.turn(chatId, text);
      setRunId(run.id);
      addLog("turn " + run.id);
      await client.streamRun(run.id, (ev: AgentEvent) => {
        addLog(JSON.stringify(ev));
        switch (ev.type) {
          case "thinking":
            setBubbles((b) => {
              const copy = [...b];
              if (thinkingIdx < 0) {
                thinkingIdx = copy.length;
                copy.push({ role: "thinking", text: ev.text || "" });
              } else {
                copy[thinkingIdx] = { role: "thinking", text: (copy[thinkingIdx]?.text || "") + (ev.text || "") };
              }
              return copy;
            });
            break;
          case "text":
            setBubbles((b) => {
              const copy = [...b];
              if (assistantIdx < 0) {
                assistantIdx = copy.length;
                copy.push({ role: "assistant", text: ev.text || "" });
              } else {
                copy[assistantIdx] = { role: "assistant", text: (copy[assistantIdx]?.text || "") + (ev.text || "") };
              }
              return copy;
            });
            break;
          case "tool_use":
            setBubbles((b) => [...b, { role: "tool", text: "🔧 " + (ev.tool?.name || "tool") + " " + JSON.stringify(ev.tool?.input ?? {}) }]);
            break;
          case "interaction": {
            const it = ev.interaction;
            if (!it) break;
            if (it.kind === "todos") {
              const mark = (s: string) => (s === "completed" ? "✅" : s === "in_progress" ? "🔄" : "⬜");
              const list = (it.items || []).map((t) => `${mark(t.status)} ${t.content}`).join("\n");
              setBubbles((b) => [...b, { role: "tool", text: "📋 To-dos\n" + list }]);
            } else {
              const head = it.kind === "plan" ? "📝 " + (it.title || "Plan") : "❓ " + (it.title || it.kind);
              setBubbles((b) => [...b, { role: "tool", text: head + (it.detail ? "\n" + it.detail : ""), interaction: it }]);
            }
            break;
          }
          case "tool_result":
            setBubbles((b) => [...b, { role: "tool", text: "↳ " + (ev.tool?.output || "").slice(0, 300) }]);
            break;
          case "result":
            if (assistantIdx < 0 && ev.result?.text) {
              setBubbles((b) => [...b, { role: "assistant", text: ev.result?.text || "" }]);
            }
            addLog(`✔ done · $${ev.result?.costUsd ?? 0} · ${ev.result?.durationMs ?? 0}ms`);
            break;
          case "error":
            setBubbles((b) => [...b, { role: "tool", text: "⚠ " + (ev.error || "error") }]);
            break;
          default:
            break;
        }
      });
    } catch (e) {
      addLog("error: " + (e as Error).message);
    } finally {
      setBusy(false);
      setRunId(null);
      onActivity?.();
    }
  };

  const send = () => {
    const text = input.trim();
    if (!text || busy) return;
    setInput("");
    void runTurn(text);
  };

  // Responding to an interaction is just the next turn (CLI-only loop): a plan approval
  // or the chosen option is sent as the next user message.
  const respond = (it: Interaction, opt: { id: string; label: string }) => {
    if (it.kind === "plan") {
      void runTurn(opt.id === "approve"
        ? "Approved — proceed with the plan."
        : "Don't proceed with that plan; I'll give revised instructions.");
    } else {
      void runTurn(opt.label);
    }
  };

  const stop = async () => {
    if (!runId) return;
    try { await client.cancelRun(runId); addLog("cancel " + runId); }
    catch (e) { addLog("cancel failed: " + (e as Error).message); }
  };

  const onKey = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") void send();
  };

  return (
    <>
      <div className="card">
        <h2>Chat <span className="muted">{chatId}</span></h2>
        <div className="thread" ref={threadRef}>
          {bubbles.length === 0 && (
            <div className="muted">
              Send a message to start.{info && !info.configured ? " ⚠ agent not configured — set auth first." : ""}
            </div>
          )}
          {bubbles.map((b, i) => (
            <div key={i} className={"msg " + b.role}>
              {b.text}
              {b.interaction?.options && b.interaction.options.length > 0 && (
                <div className="notif-actions">
                  {b.interaction.options.map((o) => (
                    <button key={o.id} className="chip-btn" disabled={busy}
                      onClick={() => respond(b.interaction!, o)}>{o.label}</button>
                  ))}
                </div>
              )}
            </div>
          ))}
        </div>
        <div className="composer">
          <textarea value={input} onChange={(e) => setInput(e.target.value)} onKeyDown={onKey}
            placeholder="Message the agent…  (⌘/Ctrl+Enter)" />
          {busy && runId
            ? <button onClick={() => void stop()}>Stop</button>
            : <button className="primary" onClick={() => void send()} disabled={busy}>{busy ? "…" : "Send"}</button>}
        </div>
      </div>

      <div className="card">
        <h2>Raw event stream</h2>
        <div className="log">{log.map((l, i) => <div key={i}>{l}</div>)}</div>
      </div>
    </>
  );
}
