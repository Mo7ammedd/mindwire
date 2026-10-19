package opencode

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
	"github.com/oblien/mindwire/packages/daemon/internal/workspacepath"
)

// Only the columns consumed by the reader; matching the native v1 session,
// message and part tables. Extra native columns must not affect the reader.
const nativeFixtureSchema = `
CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT NOT NULL, title TEXT NOT NULL,
 parent_id TEXT, time_archived INTEGER, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, revert TEXT);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, data TEXT NOT NULL);
CREATE TABLE part (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, message_id TEXT NOT NULL, data TEXT NOT NULL);`

func nativeFixture(t *testing.T) *sql.DB {
	t.Helper()
	base := t.TempDir()
	t.Setenv("XDG_DATA_HOME", base)
	t.Setenv("OPENCODE_DB", "")
	if err := os.Mkdir(filepath.Join(base, "opencode"), 0700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", nativeDBPath())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	fixtureExec(t, db, nativeFixtureSchema)
	return db
}

func fixtureExec(t *testing.T, db *sql.DB, query string, args ...any) {
	t.Helper()
	if _, err := db.Exec(query, args...); err != nil {
		t.Fatal(err)
	}
}

func fixtureSession(t *testing.T, db *sql.DB, id, cwd, title string) {
	t.Helper()
	fixtureExec(t, db, `INSERT INTO session(id,directory,title,time_created,time_updated) VALUES(?,?,?,1001,2002)`, id, cwd, title)
}

func TestNativeSessionDiscoveryIncludesEveryFolderAndExactAliases(t *testing.T) {
	db := nativeFixture(t)
	cwd, _ := workspacepath.Canonical(t.TempDir())
	sibling := cwd + "-sibling"
	alias := filepath.Join(t.TempDir(), "alias")
	if err := os.Symlink(cwd, alias); err != nil {
		t.Fatal(err)
	}
	fixtureSession(t, db, "ses_first", alias, "Native\ntitle")
	fixtureSession(t, db, "ses_sibling", sibling, "Sibling folder")
	fixtureSession(t, db, "ses_child", cwd, "Child")
	fixtureSession(t, db, "ses_archived", cwd, "Archived")
	fixtureSession(t, db, "../invalid", cwd, "Invalid ID")
	fixtureSession(t, db, "ses_relative", "relative/path", "Invalid directory")
	fixtureExec(t, db, `UPDATE session SET parent_id='ses_first' WHERE id='ses_child'`)
	fixtureExec(t, db, `UPDATE session SET time_archived=3000 WHERE id='ses_archived'`)
	rows, err := (adapter{}).ListSessions(context.Background(), cwd)
	if err != nil || len(rows) != 1 || rows[0].ID != "ses_first" || rows[0].CWD != cwd || rows[0].Title != "Native title" {
		t.Fatalf("exact project inventory: %+v %v", rows, err)
	}
	if rows[0].CreatedAt != "1970-01-01T00:00:01.001Z" || rows[0].UpdatedAt != "1970-01-01T00:00:02.002Z" {
		t.Fatalf("millisecond timestamps: %+v", rows[0])
	}
	for i := range 120 {
		fixtureSession(t, db, fmt.Sprintf("ses_extra_%03d", i), sibling, "More")
	}
	rows, err = (adapter{}).ListSessions(context.Background(), "")
	if err != nil || len(rows) != 122 {
		t.Fatalf("global inventory was filtered or truncated: %d %v", len(rows), err)
	}
	rows, err = (adapter{}).ListSessions(context.Background(), alias)
	if err != nil || len(rows) != 1 || rows[0].CWD != cwd {
		t.Fatalf("alias inventory: %+v %v", rows, err)
	}
}

func TestNativeDiscoveryNeverCreatesAHomeOrStartsCLI(t *testing.T) {
	base := filepath.Join(t.TempDir(), "absent")
	t.Setenv("XDG_DATA_HOME", base)
	t.Setenv("OPENCODE_DB", "")
	t.Setenv("PATH", t.TempDir())
	if rows, err := (adapter{}).ListSessions(context.Background(), ""); err != nil || len(rows) != 0 {
		t.Fatalf("fresh home: %+v %v", rows, err)
	}
	if messages, err := (adapter{}).History(agent.HistoryQuery{SessionID: "ses_absent"}); err != nil || len(messages) != 0 {
		t.Fatalf("fresh history: %+v %v", messages, err)
	}
	if _, err := os.Stat(base); !os.IsNotExist(err) {
		t.Fatal("reading created an OpenCode home")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := (adapter{}).ListSessions(ctx, ""); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled refresh: %v", err)
	}
}

func TestNativeDatabasePathHonorsOverrides(t *testing.T) {
	base := t.TempDir()
	t.Setenv("XDG_DATA_HOME", base)
	t.Setenv("OPENCODE_DB", "custom.db")
	if path := nativeDBPath(); path != filepath.Join(base, "opencode", "custom.db") {
		t.Fatal(path)
	}
	abs := filepath.Join(base, "another", "custom.db")
	t.Setenv("OPENCODE_DB", abs)
	if path := nativeDBPath(); path != abs {
		t.Fatal(path)
	}
	t.Setenv("OPENCODE_DB", ":memory:")
	if path := nativeDBPath(); path != "" {
		t.Fatal(path)
	}
}

func TestNativeReaderSeesWALAndCannotWrite(t *testing.T) {
	db := nativeFixture(t)
	fixtureExec(t, db, `PRAGMA journal_mode=WAL`)
	fixtureExec(t, db, `PRAGMA wal_autocheckpoint=0`)
	q := agent.HistoryQuery{SessionID: "ses_wal"}
	before, err := (adapter{}).HistoryRevision(q)
	if err != nil {
		t.Fatal(err)
	}
	fixtureSession(t, db, "ses_wal", t.TempDir(), "Uncheckpointed")
	walBefore, err := os.ReadFile(nativeDBPath() + "-wal")
	if err != nil {
		t.Fatal(err)
	}
	rows, err := (adapter{}).ListSessions(context.Background(), "")
	if err != nil || len(rows) != 1 || rows[0].ID != "ses_wal" {
		t.Fatalf("live WAL inventory: %+v %v", rows, err)
	}
	after, err := (adapter{}).HistoryRevision(q)
	if err != nil || before == after {
		t.Fatalf("WAL write did not change history revision: %v", err)
	}
	reader, err := nativeDB()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	if _, err = reader.Exec(`DELETE FROM session`); err == nil {
		t.Fatal("native reader allowed a database mutation")
	}
	walAfter, err := os.ReadFile(nativeDBPath() + "-wal")
	if err != nil || string(walBefore) != string(walAfter) {
		t.Fatal("discovery changed or checkpointed the native WAL")
	}
}

func TestNativeDiscoveryRejectsIncompatibleSchema(t *testing.T) {
	db := nativeFixture(t)
	fixtureExec(t, db, `ALTER TABLE session RENAME COLUMN directory TO incompatible_directory`)
	if rows, err := (adapter{}).ListSessions(context.Background(), ""); err == nil || rows != nil {
		t.Fatalf("incompatible store became an authoritative inventory: %+v %v", rows, err)
	}
}

func TestNativeOpenCodeStoreSmoke(t *testing.T) {
	if os.Getenv("MINDWIRE_TEST_OPENCODE_SESSIONS") != "1" {
		t.Skip("explicit read-only check of an existing native OpenCode store")
	}
	rows, err := (adapter{}).ListSessions(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("native OpenCode conversations discovered: %d", len(rows))
	for _, row := range rows {
		messages, err := (adapter{}).History(agent.HistoryQuery{SessionID: row.ID, CWD: row.CWD})
		if err != nil {
			t.Fatal(err)
		}
		if len(messages) > 0 {
			t.Logf("native transcript readable: %d messages", len(messages))
			return
		}
	}
	if len(rows) > 0 {
		t.Fatal("discovered conversations but could not read any native messages")
	}
}
