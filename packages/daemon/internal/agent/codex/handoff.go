package codex

import (
	"context"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
)

func (a adapter) ExportHandoff(ctx context.Context, q agent.HistoryQuery) (agent.HandoffHistory, error) {
	available := q.SessionID != "" && configBase() != "" && findRollout(configBase(), q.SessionID) != ""
	return agent.ReadHandoffSnapshot(ctx, a, q, available)
}

func (adapter) EncodeHandoff(c agent.HandoffContext, task string) (agent.HandoffInput, error) {
	// RunStream encodes Message as input_text on a new Codex thread. Native call
	// IDs and compacted vendor response items are never replayed across agents.
	return agent.EncodeHandoffPrompt(c, task, "codex", "codex/thread-v1")
}
