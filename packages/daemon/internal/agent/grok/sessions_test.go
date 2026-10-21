package grok

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
)

func writeNativeSession(t *testing.T, group, id, cwd, kind string, updates string) string {
	t.Helper()
	dir := filepath.Join(configBase(), "sessions", group, id)
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	summary, _ := json.Marshal(map[string]any{
		"info": map[string]string{"id": id, "cwd": cwd}, "session_summary": "First prompt",
		"generated_title": "Native title", "created_at": "2026-10-01T12:00:00Z",
		"updated_at": "2026-10-02T12:00:00Z", "session_kind": kind,
	})
	for name, data := range map[string][]byte{"summary.json": summary, "updates.jsonl": []byte(updates)} {
		if err := os.WriteFile(filepath.Join(dir, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestNativeGrokDiscoveryAndRichHistory(t *testing.T) {
	t.Setenv("GROK_HOME", t.TempDir())
	cwd, _ := filepath.EvalSymlinks(t.TempDir())
	alias := filepath.Join(t.TempDir(), "alias")
	if err := os.Symlink(cwd, alias); err != nil {
		t.Fatal(err)
	}
	// A legacy notification followed by current timestamped envelopes. Native
	// tool results use an array of ACP content wrappers, not a single text object.
	updates := `{"sessionId":"native-one","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Question"}}}
{"timestamp":1790856001,"method":"session/update","params":{"sessionId":"native-one","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Thinking"}}}}
{"timestamp":1790856002,"method":"session/update","params":{"sessionId":"native-one","update":{"sessionUpdate":"tool_call","toolCallId":"read-1","title":"Read file","rawInput":{"path":"a.go"}}}}
{"timestamp":1790856003,"method":"session/update","params":{"sessionId":"native-one","update":{"sessionUpdate":"tool_call_update","toolCallId":"read-1","status":"failed","content":[{"type":"content","content":{"type":"text","text":"File missing"}}]}}}
{"timestamp":1790856004,"method":"session/update","params":{"sessionId":"native-one","update":{"sessionUpdate":"plan","entries":[{"content":"Inspect code","status":"completed"}]}}}
{"timestamp":1790856005,"method":"session/update","params":{"sessionId":"native-one","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Answer "}}}}
{"timestamp":1790856006,"method":"session/update","params":{"sessionId":"native-one","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"complete"}}}}
`
	dir := writeNativeSession(t, "hashed-folder", "native-one", alias, "", updates)
	writeNativeSession(t, "hashed-folder", "fork", cwd, "fork", "")
	writeNativeSession(t, "hashed-folder", "child", cwd, "subagent", "")
	writeNativeSession(t, "sibling-folder", "sibling", cwd+"-sibling", "", "")
	rows, err := (adapter{}).ListSessions(context.Background(), cwd)
	if err != nil || len(rows) != 2 {
		t.Fatalf("scoped discovery (including forks, excluding subagents/siblings): %+v %v", rows, err)
	}
	for _, row := range rows {
		if row.CWD != cwd || row.Title != "Native title" || row.CreatedAt != "2026-10-01T12:00:00Z" {
			t.Fatalf("native metadata: %+v", row)
		}
	}
	if all, err := (adapter{}).ListSessions(context.Background(), ""); err != nil || len(all) != 3 {
		t.Fatalf("all-folder discovery: %+v %v", all, err)
	}
	q := agent.HistoryQuery{ChatID: "imported", SessionID: "native-one", CWD: cwd}
	messages, err := (adapter{}).History(q)
	if err != nil || len(messages) != 2 || messages[0].Text != "Question" || messages[1].Text != "Answer complete" {
		t.Fatalf("native messages: %+v %v", messages, err)
	}
	a := messages[1]
	if a.ChatID != q.ChatID || len(a.Parts) != 4 || a.Parts[0].Type != "thinking" || a.Parts[1].Tool.Output != "File missing" || !a.Parts[1].Tool.IsError || a.Parts[2].Interaction.Items[0].Content != "Inspect code" {
		t.Fatalf("rich transcript: %+v", a)
	}
	before, err := (adapter{}).HistoryRevision(q)
	if err != nil {
		t.Fatal(err)
	}
	updates += `{"method":"session/update","params":{"update":{"sessionUpdate":"user_message_chunk","content":{"type":"image","mimeType":"image/png","data":"aGVsbG8="}}}}` + "\n"
	if err := os.WriteFile(filepath.Join(dir, "updates.jsonl"), []byte(updates), 0600); err != nil {
		t.Fatal(err)
	}
	after, err := (adapter{}).HistoryRevision(q)
	if err != nil || after == before {
		t.Fatalf("native append failed to invalidate history: %v", err)
	}
	messages, err = (adapter{}).History(q)
	if err != nil || len(messages) != 3 || len(messages[2].Attachments) != 1 || string(messages[2].Attachments[0].Data) != "hello" {
		t.Fatalf("external image-only continuation: %+v %v", messages, err)
	}
}

func TestNativeGrokRewindsAndIncompleteWrites(t *testing.T) {
	home := filepath.Join(t.TempDir(), "not-created")
	t.Setenv("GROK_HOME", home)
	if rows, err := (adapter{}).ListSessions(context.Background(), ""); err != nil || len(rows) != 0 {
		t.Fatalf("absent home: %+v %v", rows, err)
	}
	if _, err := os.Stat(home); !os.IsNotExist(err) {
		t.Fatal("discovery initialized a Grok home")
	}
	var lines []string
	add := func(method, kind string, fields map[string]any) {
		fields["sessionUpdate"] = kind
		line, _ := json.Marshal(map[string]any{"timestamp": 1000, "method": method, "params": map[string]any{"update": fields}})
		lines = append(lines, string(line))
	}
	user := func(text string, index int) {
		add("session/update", "user_message_chunk", map[string]any{"content": map[string]string{"text": text}, "_meta": map[string]int{"promptIndex": index}})
	}
	answer := func(text string) {
		add("session/update", "agent_message_chunk", map[string]any{"content": map[string]string{"text": text}})
	}
	user("Original", 0)
	answer("First answer")
	user("Undone request", 1)
	answer("Undone answer")
	add("_x.ai/session/update", "rewind_marker", map[string]any{"target_prompt_index": 1})
	user("Replacement", 1)
	answer("Current answer")
	updates := strings.Join(lines, "\n") + "\n" + `{"method":"session/update","params":`
	cwd := t.TempDir()
	dir := writeNativeSession(t, "hashed-folder", "rewound", cwd, "", updates)
	q := agent.HistoryQuery{SessionID: "rewound", CWD: cwd, Recorded: []agent.Message{{Role: "user", Text: "Undone request"}}}
	messages, err := (adapter{}).History(q)
	if err != nil || len(messages) != 4 || messages[2].Text != "Replacement" || messages[3].Text != "Current answer" {
		t.Fatalf("rewind/torn-tail handling: %+v %v", messages, err)
	}
	if err := os.WriteFile(filepath.Join(dir, "updates.jsonl"), []byte(updates+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if partial, err := (adapter{}).History(q); err == nil || partial != nil {
		t.Fatalf("corrupt committed record returned partial history: %+v %v", partial, err)
	}
	if err := os.WriteFile(filepath.Join(dir, "summary.json"), []byte("broken"), 0600); err != nil {
		t.Fatal(err)
	}
	if rows, err := (adapter{}).ListSessions(context.Background(), ""); err == nil || rows != nil {
		t.Fatalf("corrupt metadata became an authoritative empty list: %+v %v", rows, err)
	}
}
