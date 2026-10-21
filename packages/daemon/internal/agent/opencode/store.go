package opencode

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

const nativeReadTimeout = 6 * time.Second

// OpenCode owns this database. Readers never initialize a home, run migrations,
// checkpoint the WAL, or launch a harness. Unknown schemas fail the refresh so
// the conversation index retains its last successful inventory.
// Schema: anomalyco/opencode v1.18.19, packages/core/src/session/sql.ts.
func nativeDB() (*sql.DB, error) {
	path := nativeDBPath()
	if path == "" {
		return nil, nil
	}
	info, err := os.Stat(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("OpenCode database is not a regular file")
	}
	u := url.URL{Scheme: "file", Path: path}
	q := u.Query()
	q.Set("mode", "ro")
	q.Add("_pragma", "query_only(1)")
	q.Add("_pragma", "busy_timeout(1000)")
	u.RawQuery = q.Encode()
	db, err := sql.Open("sqlite", u.String())
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	return db, nil
}

func nativeDBPath() string {
	custom := strings.TrimSpace(os.Getenv("OPENCODE_DB"))
	if custom == ":memory:" {
		return "" // another process's in-memory database cannot be discovered
	}
	if filepath.IsAbs(custom) {
		return custom
	}
	base := strings.TrimSpace(os.Getenv("XDG_DATA_HOME"))
	if !filepath.IsAbs(base) {
		home, err := os.UserHomeDir()
		if err != nil || home == "" {
			return ""
		}
		base = filepath.Join(home, ".local", "share")
	}
	if custom == "" {
		custom = "opencode.db"
	}
	return filepath.Join(base, "opencode", custom)
}

func nativeTime(ms int64) string {
	return time.UnixMilli(ms).UTC().Format(time.RFC3339Nano)
}

func nativeReadContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), nativeReadTimeout)
}
