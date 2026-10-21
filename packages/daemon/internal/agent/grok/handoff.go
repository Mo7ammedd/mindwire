package grok

import (
	"context"
	"os"
	"path/filepath"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
)

func (a adapter) ExportHandoff(ctx context.Context, q agent.HistoryQuery) (agent.HandoffHistory, error) {
	summary, err := nativeSummaryFor(q)
	if err != nil || summary == nil {
		return agent.HandoffHistory{}, err
	}
	_, err = os.Stat(filepath.Join(filepath.Dir(summary.path), "updates.jsonl"))
	if os.IsNotExist(err) {
		return agent.HandoffHistory{}, nil
	}
	if err != nil {
		return agent.HandoffHistory{}, err
	}
	return agent.ReadHandoffSnapshot(ctx, a, q, true)
}

func (adapter) EncodeHandoff(c agent.HandoffContext, task string) (agent.HandoffInput, error) {
	return agent.EncodeHandoffPrompt(c, task, "grok", "grok/acp-v1")
}
