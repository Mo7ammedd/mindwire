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
  /** Visible excerpts and file paths, up to 32 KiB. Review and edit before sending. */
  context: string;
  truncated: boolean;
  historySource: "native" | "recorded";
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
}

export interface HandoffResult {
  chatId: string;
  run: Run;
  snapshot: WorkspaceSnapshot;
}
