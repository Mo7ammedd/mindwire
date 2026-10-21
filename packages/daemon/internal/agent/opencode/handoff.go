package opencode

import (
	"context"
	"database/sql"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
)

func (a adapter) ExportHandoff(ctx context.Context, q agent.HistoryQuery) (agent.HandoffHistory, error) {
	db, err := nativeDB()
	if err != nil || db == nil {
		return agent.HandoffHistory{}, err
	}
	defer db.Close()
	var id string
	err = db.QueryRowContext(ctx, "SELECT id FROM session WHERE id=?", q.SessionID).Scan(&id)
	if err == sql.ErrNoRows {
		return agent.HandoffHistory{}, nil
	}
	if err != nil {
		return agent.HandoffHistory{}, err
	}
	return agent.ReadHandoffSnapshot(ctx, a, q, true)
}

func (adapter) EncodeHandoff(c agent.HandoffContext, task string) (agent.HandoffInput, error) {
	return agent.EncodeHandoffPrompt(c, task, "opencode", "opencode/prompt-v1")
}
