package grok

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
)

func TestHandoffRespectsNativeRewindAndMissingTranscript(t *testing.T) {
	t.Setenv("GROK_HOME", t.TempDir())
	cwd, _ := filepath.EvalSymlinks(t.TempDir())
	body := `{"sessionId":"native-one","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Retained instruction"}}}` + "\n"
	dir := writeNativeSession(t, "group", "native-one", cwd, "", body)
	q := agent.HistoryQuery{ChatID: "chat", SessionID: "native-one", CWD: cwd, Recorded: []agent.Message{{Role: "user", Text: "Discarded recorded future"}}}
	history, err := (adapter{}).ExportHandoff(context.Background(), q)
	if err != nil || !history.Available || len(history.Messages) != 1 || history.Messages[0].Text != "Retained instruction" {
		t.Fatalf("native snapshot: %+v %v", history, err)
	}
	body += `{"method":"_x.ai/session/update","params":{"sessionId":"native-one","update":{"sessionUpdate":"rewind_marker","target_prompt_index":0}}}` + "\n"
	path := filepath.Join(dir, "updates.jsonl")
	if err := os.WriteFile(path, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	empty, err := (adapter{}).ExportHandoff(context.Background(), q)
	if err != nil || !empty.Available || len(empty.Messages) != 0 {
		t.Fatalf("rewind resurrected recorded future: %+v %v", empty, err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	missing, err := (adapter{}).ExportHandoff(context.Background(), q)
	if err != nil || missing.Available {
		t.Fatalf("missing transcript became empty native context: %+v %v", missing, err)
	}
}
