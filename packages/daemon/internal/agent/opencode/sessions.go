package opencode

import (
	"context"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
	"github.com/oblien/mindwire/packages/daemon/internal/workspacepath"
)

var _ agent.SessionLister = adapter{}

// ListSessions reads metadata only. Unlike the project-scoped CLI list, this
// includes every folder without a default limit. Child agents and archived
// sessions stay out of the ordinary conversation inventory.
func (adapter) ListSessions(ctx context.Context, cwd string) ([]agent.NativeSession, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	canonical := ""
	if cwd != "" {
		var err error
		canonical, err = workspacepath.Canonical(cwd)
		if err != nil {
			return nil, err
		}
	}
	db, err := nativeDB()
	if err != nil || db == nil {
		return nil, err
	}
	defer db.Close()
	ctx, cancel := context.WithTimeout(ctx, nativeReadTimeout)
	defer cancel()
	rows, err := db.QueryContext(ctx, `SELECT id, directory, title, time_created, time_updated
		FROM session WHERE parent_id IS NULL AND time_archived IS NULL
		ORDER BY time_updated DESC, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []agent.NativeSession{}
	for rows.Next() {
		var id, directory, title string
		var created, updated int64
		if err := rows.Scan(&id, &directory, &title, &created, &updated); err != nil {
			return nil, err
		}
		actual, err := workspacepath.Canonical(directory)
		if err != nil || canonical != "" && actual != canonical || !agent.ValidNativeSessionID(id) {
			continue
		}
		if created <= 0 {
			created = updated
		}
		updated = max(created, updated)
		out = append(out, agent.NativeSession{ID: id, CWD: actual,
			Title:     agent.SessionTitle(agent.FirstNonEmpty(title, "OpenCode conversation")),
			CreatedAt: nativeTime(created), UpdatedAt: nativeTime(updated)})
	}
	if err := rows.Err(); err != nil {
		return nil, err // a partial inventory must never prune cached conversations
	}
	return out, nil
}
