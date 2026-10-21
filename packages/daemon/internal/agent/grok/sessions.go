package grok

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
	"github.com/oblien/mindwire/packages/daemon/internal/workspacepath"
)

var _ agent.SessionLister = adapter{}

// Grok's summary.json is the native index entry; directory names may be hashed.
// Trust its explicit cwd rather than decoding the enclosing folder name.
type nativeSummary struct {
	Info struct {
		ID  string `json:"id"`
		CWD string `json:"cwd"`
	} `json:"info"`
	Summary        string    `json:"session_summary"`
	GeneratedTitle string    `json:"generated_title"`
	Created        time.Time `json:"created_at"`
	Updated        time.Time `json:"updated_at"`
	LastActive     time.Time `json:"last_active_at"`
	Kind           string    `json:"session_kind"`
	Hidden         *bool     `json:"hidden"`
	path           string
}

func (adapter) ListSessions(ctx context.Context, cwd string) ([]agent.NativeSession, error) {
	summaries, err := nativeSummaries(ctx, cwd, "")
	if err != nil {
		return nil, err
	}
	out := make([]agent.NativeSession, 0, len(summaries))
	for _, s := range summaries {
		hidden := strings.HasPrefix(s.Kind, "subagent")
		if s.Hidden != nil {
			hidden = *s.Hidden
		}
		if hidden {
			continue
		}
		out = append(out, agent.NativeSession{ID: s.Info.ID, CWD: s.Info.CWD,
			Title:     agent.SessionTitle(agent.FirstNonEmpty(s.GeneratedTitle, s.Summary, "Grok conversation")),
			CreatedAt: s.Created.UTC().Format(time.RFC3339Nano), UpdatedAt: s.Updated.UTC().Format(time.RFC3339Nano)})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].UpdatedAt == out[j].UpdatedAt {
			return out[i].ID < out[j].ID
		}
		a, _ := time.Parse(time.RFC3339Nano, out[i].UpdatedAt)
		b, _ := time.Parse(time.RFC3339Nano, out[j].UpdatedAt)
		return a.After(b)
	})
	return out, nil
}

func nativeSummaries(ctx context.Context, cwd, id string) ([]nativeSummary, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if id != "" && !agent.ValidNativeSessionID(id) {
		return nil, fmt.Errorf("invalid Grok session ID")
	}
	canonical := ""
	if cwd != "" {
		var err error
		canonical, err = workspacepath.Canonical(cwd)
		if err != nil {
			return nil, err
		}
	}
	base := configBase()
	if base == "" {
		return nil, nil
	}
	root := filepath.Join(base, "sessions")
	groups, err := os.ReadDir(root)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []nativeSummary
	for _, group := range groups {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if !group.IsDir() {
			continue
		}
		paths := []string{filepath.Join(root, group.Name(), id, "summary.json")}
		if id == "" {
			entries, err := os.ReadDir(filepath.Join(root, group.Name()))
			if os.IsNotExist(err) {
				continue
			}
			if err != nil {
				return nil, err
			}
			paths = nil
			for _, entry := range entries {
				if entry.IsDir() && agent.ValidNativeSessionID(entry.Name()) {
					paths = append(paths, filepath.Join(root, group.Name(), entry.Name(), "summary.json"))
				}
			}
		}
		for _, path := range paths {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			f, err := os.Open(path)
			if os.IsNotExist(err) {
				continue
			}
			if err != nil {
				return nil, err
			}
			data, err := io.ReadAll(io.LimitReader(f, (1<<20)+1))
			info, statErr := f.Stat()
			f.Close()
			if err != nil {
				return nil, err
			}
			if statErr != nil {
				return nil, statErr
			}
			var s nativeSummary
			if len(data) > 1<<20 || json.Unmarshal(data, &s) != nil {
				return nil, fmt.Errorf("invalid Grok session summary")
			}
			if !agent.ValidNativeSessionID(s.Info.ID) || s.Info.ID != filepath.Base(filepath.Dir(path)) {
				continue
			}
			actual, err := workspacepath.Canonical(s.Info.CWD)
			if err != nil || canonical != "" && actual != canonical {
				continue
			}
			s.Info.CWD, s.path = actual, path
			if !s.LastActive.IsZero() {
				s.Updated = s.LastActive
			}
			if s.Updated.IsZero() {
				s.Updated = info.ModTime()
			}
			if s.Created.IsZero() {
				s.Created = s.Updated
			}
			if s.Updated.Before(s.Created) {
				s.Updated = s.Created
			}
			out = append(out, s)
		}
	}
	return out, nil
}

func nativeSummaryFor(q agent.HistoryQuery) (*nativeSummary, error) {
	if q.SessionID == "" {
		return nil, nil
	}
	summaries, err := nativeSummaries(context.Background(), q.CWD, q.SessionID)
	if err != nil || len(summaries) == 0 {
		return nil, err
	}
	if len(summaries) != 1 {
		return nil, fmt.Errorf("ambiguous Grok session directory")
	}
	return &summaries[0], nil
}
