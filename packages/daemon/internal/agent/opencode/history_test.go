package opencode

import (
	"database/sql"
	"encoding/json"
	"testing"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
)

func fixtureMessage(t *testing.T, db *sql.DB, id, role string, created int64, parts ...map[string]any) {
	t.Helper()
	data, _ := json.Marshal(map[string]any{"role": role})
	fixtureExec(t, db, `INSERT INTO message VALUES(?, 'ses_history', ?, ?)`, id, created, string(data))
	// Insert in reverse order so history must restore the native part order.
	for i := len(parts) - 1; i >= 0; i-- {
		part := parts[i]
		data, _ := json.Marshal(part)
		fixtureExec(t, db, `INSERT INTO part VALUES(?, 'ses_history', ?, ?)`, part["id"], id, string(data))
	}
}

func TestNativeHistoryPreservesRichTranscriptAndHidesContext(t *testing.T) {
	db := nativeFixture(t)
	cwd := t.TempDir()
	fixtureSession(t, db, "ses_history", cwd, "Existing conversation")
	fixtureMessage(t, db, "msg_001", "user", 1001,
		map[string]any{"id": "prt_001", "type": "text", "text": "Private instructions", "synthetic": true},
		map[string]any{"id": "prt_002", "type": "text", "text": "Review this"},
		map[string]any{"id": "prt_003", "type": "file", "mime": "image/png", "filename": "screen.png", "url": "data:image/png;base64,aGVsbG8="},
		map[string]any{"id": "prt_004", "type": "text", "text": "Ignored context", "ignored": true})
	fixtureMessage(t, db, "msg_002", "assistant", 2002,
		map[string]any{"id": "prt_010", "type": "reasoning", "text": "Checking the code"},
		map[string]any{"id": "prt_011", "type": "tool", "callID": "call_read", "tool": "read", "state": map[string]any{
			"status": "completed", "input": map[string]any{"filePath": "/repo/main.go"}, "output": "package main"}},
		map[string]any{"id": "prt_012", "type": "tool", "callID": "call_bash", "tool": "bash", "state": map[string]any{
			"status": "error", "input": map[string]any{"command": "false"}, "error": "exit code 1"}},
		map[string]any{"id": "prt_013", "type": "tool", "tool": "todowrite", "state": map[string]any{
			"status": "completed", "input": map[string]any{"todos": []any{map[string]any{"content": "Review", "status": "completed"}}}}},
		map[string]any{"id": "prt_014", "type": "text", "text": "Review complete"},
		map[string]any{"id": "prt_015", "type": "step-finish"})
	fixtureMessage(t, db, "msg_003", "user", 3003,
		map[string]any{"id": "prt_020", "type": "file", "mime": "text/plain", "filename": "notes.txt", "url": "file:///repo/notes%20one.txt"})
	fixtureMessage(t, db, "msg_004", "user", 4004,
		map[string]any{"id": "prt_030", "type": "text", "text": "Hidden", "synthetic": true})
	fixtureExec(t, db, `UPDATE message SET data='{"role":"user","summary":{"title":"Review","body":"Details"}}' WHERE id='msg_001'`)
	q := agent.HistoryQuery{ChatID: "imported-chat", SessionID: "ses_history", CWD: cwd}
	messages, err := (adapter{}).History(q)
	if err != nil || len(messages) != 3 {
		t.Fatalf("native history: %+v %v", messages, err)
	}
	u, a, file := messages[0], messages[1], messages[2]
	if u.ID != "msg_001" || u.ChatID != q.ChatID || u.Role != "user" || u.Text != "Review this" || len(u.Attachments) != 1 || string(u.Attachments[0].Data) != "hello" {
		t.Fatalf("user/attachment: %+v", u)
	}
	if u.CreatedAt != "1970-01-01T00:00:01.001Z" || u.Attachments[0].Name != "screen.png" {
		t.Fatalf("user metadata: %+v", u)
	}
	if a.Role != "assistant" || a.Text != "Review complete" || len(a.Parts) != 5 || a.Parts[0].Type != "thinking" || a.Parts[4].Text != a.Text {
		t.Fatalf("ordered assistant transcript: %+v", a)
	}
	read, bash := a.Parts[1].Tool, a.Parts[2].Tool
	if read == nil || read.ID != "call_read" || read.Output != "package main" || read.Action.Kind != agent.KindFileRead {
		t.Fatalf("read tool: %+v", read)
	}
	if bash == nil || !bash.IsError || bash.Output != "exit code 1" || bash.Action.Shell.Command != "false" {
		t.Fatalf("error tool: %+v", bash)
	}
	if todos := a.Parts[3].Interaction; todos == nil || todos.Kind != "todos" || todos.Items[0].Content != "Review" {
		t.Fatalf("todos: %+v", todos)
	}
	if file.Text != "" || len(file.Attachments) != 1 || file.Attachments[0].Path != "/repo/notes one.txt" {
		t.Fatalf("file-only user turn: %+v", file)
	}
	fixtureExec(t, db, `UPDATE part SET data = '{"type":"text","text":"Changed outside Mindwire"}' WHERE id='prt_014'`)
	messages, err = (adapter{}).History(q)
	if err != nil || messages[1].Text != "Changed outside Mindwire" {
		t.Fatalf("native edits were not reflected: %+v %v", messages, err)
	}
}

func TestNativeHistoryCompactionAndRevert(t *testing.T) {
	db := nativeFixture(t)
	cwd := t.TempDir()
	fixtureSession(t, db, "ses_history", cwd, "Compacted")
	fixtureMessage(t, db, "msg_001", "user", 1000, map[string]any{"id": "prt_001", "type": "text", "text": "Original"})
	fixtureMessage(t, db, "msg_002", "user", 2000, map[string]any{"id": "prt_002", "type": "compaction", "auto": true})
	fixtureMessage(t, db, "msg_003", "assistant", 3000, map[string]any{"id": "prt_003", "type": "text", "text": "Summary context"})
	fixtureExec(t, db, `UPDATE message SET data='{"role":"assistant","summary":true}' WHERE id='msg_003'`)
	fixtureMessage(t, db, "msg_004", "user", 4000, map[string]any{"id": "prt_004", "type": "text", "text": "Continue", "synthetic": true})
	fixtureMessage(t, db, "msg_005", "user", 5000, map[string]any{"id": "prt_005", "type": "text", "text": "Reverted request"})
	fixtureMessage(t, db, "msg_006", "assistant", 6000, map[string]any{"id": "prt_006", "type": "text", "text": "Reverted answer"})
	fixtureExec(t, db, `UPDATE session SET revert='{"messageID":"msg_005"}' WHERE id='ses_history'`)
	messages, err := (adapter{}).History(agent.HistoryQuery{SessionID: "ses_history", CWD: cwd})
	if err != nil || len(messages) != 2 {
		t.Fatalf("compacted/reverted transcript: %+v %v", messages, err)
	}
	marker := messages[1]
	if marker.Role != "system" || len(marker.Parts) != 1 || marker.Parts[0].Compaction == nil || marker.Parts[0].Compaction.Trigger != "auto" || marker.Parts[0].Compaction.Summary != "Summary context" {
		t.Fatalf("compaction summary: %+v", marker)
	}
}

func TestNativeHistoryFailsRatherThanReturningPartialOrWrongConversation(t *testing.T) {
	db := nativeFixture(t)
	cwd := t.TempDir()
	fixtureSession(t, db, "ses_history", cwd, "Existing")
	fixtureMessage(t, db, "msg_001", "user", 1000, map[string]any{"id": "prt_001", "type": "text", "text": "Valid prefix"})
	fixtureMessage(t, db, "msg_002", "assistant", 2000, map[string]any{"id": "prt_002", "type": "text", "text": "Broken suffix"})
	fixtureExec(t, db, `UPDATE part SET data='broken JSON' WHERE id='prt_002'`)
	for _, q := range []agent.HistoryQuery{
		{SessionID: "ses_history", CWD: cwd},
		{SessionID: "ses_history", CWD: t.TempDir()},
		{SessionID: "../invalid", CWD: cwd},
	} {
		if rows, err := (adapter{}).History(q); err == nil || rows != nil {
			t.Fatalf("partial or wrong transcript accepted: %+v %v", rows, err)
		}
	}
	if rows, err := (adapter{}).History(agent.HistoryQuery{SessionID: "ses_missing"}); err != nil || len(rows) != 0 {
		t.Fatalf("absent session: %+v %v", rows, err)
	}
	if (adapter{}).Capabilities().History != agent.SupportNative {
		t.Fatal("API would never read imported history")
	}
	if _, deletes := any(adapter{}).(agent.HistoryDeleter); deletes {
		t.Fatal("importing must not claim database deletion support")
	}
}

func TestNativeHistoryRetainsRecordedFailedStartsUntilNativeUndo(t *testing.T) {
	db := nativeFixture(t)
	fixtureSession(t, db, "ses_history", t.TempDir(), "Existing")
	fixtureMessage(t, db, "msg_001", "user", 1000, map[string]any{"id": "prt_001", "type": "text", "text": "Original"})
	q := agent.HistoryQuery{SessionID: "ses_history", Recorded: []agent.Message{
		{ID: "recorded-user", Role: "user", Text: "Failed prompt", CreatedAt: nativeTime(3000)},
		{ID: "recorded-error", Role: "assistant", Text: "Provider unavailable", CreatedAt: nativeTime(4000)},
	}}
	messages, err := (adapter{}).History(q)
	if err != nil || len(messages) != 3 || messages[2].Text != "Provider unavailable" {
		t.Fatalf("recorded failure lost after enabling native history: %+v %v", messages, err)
	}
	fixtureExec(t, db, `UPDATE session SET revert='{"messageID":"msg_002"}' WHERE id='ses_history'`)
	messages, err = (adapter{}).History(q)
	if err != nil || len(messages) != 1 || messages[0].Text != "Original" {
		t.Fatalf("recorded fallback undid native undo: %+v %v", messages, err)
	}
}
