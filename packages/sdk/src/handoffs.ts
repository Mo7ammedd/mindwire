import type { Run } from "./run.js";
import type { WorkspaceSnapshot } from "./workspace.js";

export interface HandoffOrigin {
  chatId: string;
  agentId: string;
  title: string;
  runId?: string;
}

export interface HandoffPreview {
  source: HandoffOrigin;
  /** Rendered portable context, including compaction and omissions, up to 32 KiB. */
  context: string;
  truncated: boolean;
  historySource: "native" | "recorded";
  /** Versioned portable state, including compaction and known omissions. */
  capsule: HandoffContext;
  /** Bind this digest to a reviewed submission; stale context returns 409. */
  digest: string;
  losses?: HandoffLoss[];
}

export interface HandoffRequest {
  /** New destination ID. Keep this and requestId unchanged when retrying. */
  newChatId: string;
  requestId: string;
  /** Saved profile ID on the same computer, using a different agent type. */
  targetAgentId: string;
  task: string;
  /** Reviewed context. Omit to capture the source at admission. Max 32 KiB. */
  context?: string;
  /** Required with context. Use the digest from previewHandoff. */
  previewDigest?: string;
}

export interface HandoffLoss { code: string; count: number }
export interface HandoffArtifact {
  name?: string; path?: string; artifactId?: string; mime?: string; bytes?: number; available: boolean;
}
export interface HandoffTool {
  kind: "file_edit" | "file_read" | "shell" | "search" | "web_search" | "web_fetch" | "mcp" | "other";
  title?: string;
  status: "completed" | "failed" | "unknown";
  files?: { path: string; op?: string }[];
  command?: string; exitCode?: number; output?: string;
}
export interface HandoffContext {
  version: 1;
  source: {
    agentType: string; chatId: string; title?: string; runId?: string;
    revision: string; history: "native" | "recorded"; forked?: boolean;
  };
  goal?: string;
  summary?: { messageId?: string; text: string };
  tasks?: { content: string; status: string }[];
  turns?: { id?: string; role: "user" | "assistant"; text?: string; tools?: HandoffTool[]; artifacts?: HandoffArtifact[] }[];
  losses?: HandoffLoss[];
  reviewed?: boolean;
}

export interface HandoffResult {
  chatId: string;
  run: Run;
  snapshot: WorkspaceSnapshot;
}
