// Mirrors the daemon's unified protocol (internal/agent).

export type Support = "none" | "native" | "emulated";

export interface Capabilities {
  output: string;
  history: Support;
  sessions: Support;
  resume: boolean;
  toolEvents: boolean;
  cancel: boolean;
  persistent: boolean;
  models: boolean;
}

export interface Field {
  key: string;
  label: string;
  type: string; // text | secret | select | toggle
  required?: boolean;
  placeholder?: string;
  help?: string;
  options?: { value: string; label: string }[];
  default?: string;
}

export interface AuthMethod {
  id: string;
  label: string;
  help?: string;
  interactive?: boolean;
  fields?: Field[];
}

export interface AuthState {
  method: string;
  status: string; // needs_input | pending | complete | error
  url?: string;
  code?: string;
  message?: string;
  fields?: Field[];
}

export interface AuthStatus {
  configured: boolean;
  method?: string;
  detail?: string;
}

export interface AgentInfo {
  version: string;
  agentType: string;
  name: string;
  capabilities: Capabilities;
  schema: { sections: { title: string; fields: Field[] }[] };
  authMethods: AuthMethod[];
  authStatus: AuthStatus;
  installedVersion: string;
  configured: boolean;
}

export interface Run {
  id: string;
  chatId: string;
  status: string;
  error?: string;
  replyId?: string;
  createdAt: string;
  endedAt?: string;
}

export interface Message {
  id: string;
  chatId: string;
  role: string;
  text: string;
  createdAt: string;
}

export interface ChatSummary {
  chatId: string;
  sessionId?: string;
  title: string;
  messages: number;
  updatedAt: string;
  lastStatus?: string;
}

export interface ToolEvent {
  id?: string;
  name?: string;
  input?: unknown;
  output?: string;
  isError?: boolean;
}

export interface ResultInfo {
  text?: string;
  isError?: boolean;
  sessionId?: string;
  costUsd?: number;
  numTurns?: number;
  durationMs?: number;
}

export interface TodoItem {
  content: string;
  status: string; // pending | in_progress | completed
}

// A structured, agent-defined prompt/feedback the client renders generically.
export interface Interaction {
  id?: string;
  kind: string; // todos | approval | choice | select | input | plan
  title?: string;
  detail?: string;
  items?: TodoItem[];
  options?: { id: string; label: string }[];
  needsResponse?: boolean;
  meta?: Record<string, unknown>;
}

export type EventType =
  | "session" | "text" | "thinking" | "tool_use" | "tool_result"
  | "result" | "error" | "status" | "interaction";

export interface AgentEvent {
  type: EventType;
  sessionId?: string;
  text?: string;
  delta?: boolean;
  tool?: ToolEvent;
  result?: ResultInfo;
  interaction?: Interaction;
  error?: string;
  meta?: Record<string, unknown>;
  at?: string;
}

// A daemon notification (mirrors agent.Notification) — pushed to Oblien and the local feed.
export interface Notification {
  condition: string; // finished | error | waiting_approval | waiting_feedback | waiting_input
  title: string;
  body: string;
  agent?: string;
  chatId?: string;
  runId?: string;
  actions?: { id: string; label: string }[];
}

export interface SetupResult {
  ok: boolean;
  steps: { name: string; status: string; output?: string }[];
}

export interface Check {
  name: string;
  status: string; // ok | warn | fail
  detail?: string;
}

export interface DoctorReport {
  ok: boolean;
  checks: Check[];
}
