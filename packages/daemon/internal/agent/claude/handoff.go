package claude

import (
	"context"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
)

func (a adapter) ExportHandoff(ctx context.Context, q agent.HistoryQuery) (agent.HandoffHistory, error) {
	available := q.SessionID != "" && configBase() != "" && findTranscript(configBase(), q.CWD, q.SessionID) != ""
	return agent.ReadHandoffSnapshot(ctx, a, q, available)
}

func (adapter) EncodeHandoff(c agent.HandoffContext, task string) (agent.HandoffInput, error) {
	// The normal Claude stream-json transport creates a native user content block,
	// retaining Claude's own settings, permissions and fresh session identity.
	return agent.EncodeHandoffPrompt(c, task, "claude-code", "claude-code/user-v1")
}
