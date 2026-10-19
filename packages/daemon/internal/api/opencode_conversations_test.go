package api

import (
	"database/sql"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
	"github.com/oblien/mindwire/packages/daemon/internal/conversations"
	"github.com/oblien/mindwire/packages/daemon/internal/registry"
)

func TestOpenCodeConversationBrowseImportAndNativeHistoryHTTP(t *testing.T) {
	h, store, a := newRegistryAPIEnv(t)
	h = registryAuthenticated(h)
	ag, ok := a.sup.Resolve("opencode")
	if !ok {
		t.Fatal("OpenCode backend adapter is not registered")
	}
	a.conversations = conversations.New(a.registry, store, []agent.Adapter{ag.Adapter}, &a.registryMu, a.sup.Busy)
	cwd := t.TempDir()
	db, err := sql.Open("sqlite", os.Getenv("OPENCODE_DB"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	exec := func(query string, args ...any) {
		t.Helper()
		if _, err := db.Exec(query, args...); err != nil {
			t.Fatal(err)
		}
	}
	exec(`PRAGMA journal_mode=WAL`)
	exec(`PRAGMA wal_autocheckpoint=0`)
	exec(`CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT, title TEXT,
		parent_id TEXT, time_archived INTEGER, time_created INTEGER, time_updated INTEGER, revert TEXT);
		CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
		CREATE TABLE part (id TEXT PRIMARY KEY, session_id TEXT, message_id TEXT, data TEXT);`)
	exec(`INSERT INTO session VALUES('ses_existing', ?, 'Started in OpenCode', NULL, NULL, 1000, 2000, NULL)`, cwd)
	exec(`INSERT INTO message VALUES('msg_original', 'ses_existing', 1000, '{"role":"user"}')`)
	exec(`INSERT INTO part VALUES('prt_original', 'ses_existing', 'msg_original', '{"type":"text","text":"Already in OpenCode"}')`)
	// The shared browser checks read-only discovery and idempotent opening.
	snapshot := openGlobalNativeChat(t, h, a, "opencode")
	if len(snapshot.Chats) != 1 || len(snapshot.Projects) != 1 || len(snapshot.Agents) != 1 {
		t.Fatalf("native import: %+v", snapshot)
	}
	chat := snapshot.Chats[0]
	if chat.SessionID != "ses_existing" || store.Session("opencode", chat.ID) != "ses_existing" || snapshot.Agents[0].AgentType != "opencode" {
		t.Fatalf("original identity was not retained: %+v", snapshot)
	}
	endpoint := "/chats/" + chat.ID + "/messages?paged=true&limit=12"
	read := func(suffix string) messagePage {
		t.Helper()
		response := serve(t, h, "GET", endpoint+suffix, "")
		var page messagePage
		if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &page) != nil {
			t.Fatalf("imported history: %d %s", response.Code, response.Body.String())
		}
		return page
	}
	first := read("")
	if first.Revision == "" || len(first.Messages) != 1 || !strings.Contains(string(first.Messages[0]), "Already in OpenCode") {
		t.Fatalf("native history: %+v", first)
	}
	if unchanged := read("&ifRevision=" + first.Revision); !unchanged.NotModified {
		t.Fatal("unchanged native history was downloaded again")
	}
	exec(`INSERT INTO message VALUES('msg_external', 'ses_existing', 3000, '{"role":"assistant"}')`)
	exec(`INSERT INTO part VALUES('prt_external', 'ses_existing', 'msg_external', '{"type":"text","text":"Continued in OpenCode"}')`)
	exec(`UPDATE session SET title='Renamed in OpenCode', time_updated=3000`)
	changed := read("&ifRevision=" + first.Revision)
	if changed.NotModified || changed.Revision == first.Revision || len(changed.Messages) != 2 || !strings.Contains(string(changed.Messages[1]), "Continued in OpenCode") {
		t.Fatalf("WAL continuation was hidden: %+v", changed)
	}
	response := serve(t, h, "GET", "/workspace?refresh=true", "")
	var refreshed registry.Snapshot
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &refreshed) != nil || len(refreshed.Chats) != 1 || refreshed.Chats[0].ID != chat.ID || refreshed.Chats[0].Title != "Renamed in OpenCode" {
		t.Fatalf("project discovery duplicated or missed imported chat: %d %s", response.Code, response.Body.String())
	}
	if len(store.Messages(chat.ID)) != 0 {
		t.Fatal("import copied native transcript messages into Mindwire")
	}
	// An incompatible future store reports an issue and retains the last list.
	exec(`ALTER TABLE session RENAME COLUMN directory TO changed_directory`)
	response = serve(t, h, "GET", "/workspace/conversations?refresh=true", "")
	var page conversations.Page
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &page) != nil || len(page.Issues) != 1 || len(page.Items) != 1 || page.Items[0].ChatID != chat.ID {
		t.Fatalf("failed discovery discarded cached chat: %d %s", response.Code, response.Body.String())
	}
}
