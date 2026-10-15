import type {
  AgentEvent, AgentInfo, AuthMethod, AuthState, AuthStatus, ChatSummary, DoctorReport, Message,
  Notification, Run, SetupResult,
} from "./types";

/** Typed client for the Mindwire daemon (HTTP + SSE). Run the daemon with DEV_CORS=1. */
export class DaemonClient {
  constructor(public baseURL: string, public token = "") {
    this.baseURL = baseURL.replace(/\/+$/, "");
  }

  private headers(json: boolean): Record<string, string> {
    const h: Record<string, string> = {};
    if (json) h["Content-Type"] = "application/json";
    if (this.token) h["Authorization"] = "Bearer " + this.token;
    return h;
  }

  private async req<T>(path: string, opts: { method?: string; json?: unknown } = {}): Promise<T> {
    const init: RequestInit = { method: opts.method ?? "GET", headers: this.headers(opts.json !== undefined) };
    if (opts.json !== undefined) init.body = JSON.stringify(opts.json);
    const r = await fetch(this.baseURL + path, init);
    if (!r.ok && r.status !== 204) throw new Error(`${path} → ${r.status} ${await r.text().catch(() => "")}`);
    if (r.status === 204) return undefined as T;
    return (await r.json()) as T;
  }

  agent() { return this.req<AgentInfo>("/agent"); }
  catalog() { return this.req<{ version: string; agents: { id: string; name: string; tagline: string }[] }>("/catalog"); }
  setup(force = false) { return this.req<SetupResult>(force ? "/update" : "/setup", { method: "POST" }); }
  authMethods() { return this.req<AuthMethod[]>("/auth/methods"); }
  authBegin(method: string) { return this.req<AuthState>("/auth/begin", { method: "POST", json: { method } }); }
  authStep(input: Record<string, string>) { return this.req<AuthState>("/auth/step", { method: "POST", json: input }); }
  authStatus() { return this.req<AuthStatus>("/auth/status"); }
  config() { return this.req<Record<string, string>>("/config"); }
  setConfig(cfg: Record<string, string>) { return this.req<void>("/config", { method: "PUT", json: cfg }); }
  chats() { return this.req<ChatSummary[]>("/chats"); }
  messages(chatId: string) { return this.req<Message[]>(`/chats/${encodeURIComponent(chatId)}/messages`); }
  turn(chatId: string, message: string) { return this.req<Run>("/turns", { method: "POST", json: { chatId, message } }); }
  cancelRun(runId: string) { return this.req<void>(`/runs/${encodeURIComponent(runId)}/cancel`, { method: "POST" }); }
  doctor() { return this.req<DoctorReport>("/doctor"); }

  /** Stream a run's unified events (SSE over fetch, so the bearer header works). */
  streamRun(runId: string, onEvent: (e: AgentEvent) => void, signal?: AbortSignal): Promise<void> {
    return this.sse<AgentEvent>(`/runs/${encodeURIComponent(runId)}/stream`, onEvent, signal);
  }

  /** Stream the daemon's live notification feed (finished/error/waiting_*). */
  streamNotifications(onNote: (n: Notification) => void, signal?: AbortSignal): Promise<void> {
    return this.sse<Notification>("/notify/stream", onNote, signal);
  }

  /** Shared SSE-over-fetch reader: parses `data:` lines into JSON items. */
  private async sse<T>(path: string, onItem: (x: T) => void, signal?: AbortSignal): Promise<void> {
    const r = await fetch(this.baseURL + path, { headers: this.headers(false), signal });
    if (!r.ok || !r.body) throw new Error(`${path} → ${r.status}`);
    const reader = r.body.getReader();
    const dec = new TextDecoder();
    let buf = "";
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let i: number;
      while ((i = buf.indexOf("\n\n")) >= 0) {
        const chunk = buf.slice(0, i);
        buf = buf.slice(i + 2);
        const line = chunk.split("\n").find((l) => l.startsWith("data:"));
        if (line) {
          try { onItem(JSON.parse(line.slice(5).trim()) as T); } catch { /* ignore malformed */ }
        }
      }
    }
  }
}
