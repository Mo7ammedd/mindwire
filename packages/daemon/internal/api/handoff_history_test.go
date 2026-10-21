package api

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/oblien/mindwire/packages/daemon/internal/handoffs"
	"github.com/oblien/mindwire/packages/daemon/internal/registry"
	"github.com/oblien/mindwire/packages/daemon/internal/session"
)

func TestMissingNativeTranscriptKeepsRecordedContext(t *testing.T) {
	h, store, a := newRegistryAPIEnv(t)
	h = registryAuthenticated(h)
	const source = "recorded-source"
	if err := a.registry.Import(registry.Import{
		Agents:   []registry.Agent{{Record: registry.Record{ID: "source-profile"}, Name: "Source", AgentType: "handoff-source"}},
		Projects: []registry.Project{{Record: registry.Record{ID: "project"}, Name: "App", Path: t.TempDir()}},
		Chats:    []registry.Chat{{Record: registry.Record{ID: source}, AgentID: "source-profile", ProjectID: "project", Title: "Recorded history", SessionID: "missing-native-transcript"}},
	}); err != nil {
		t.Fatal(err)
	}
	const decision = "Preserve the API contract and verify failed checkout recovery."
	if err := store.AddMessage(session.Message{ID: "recorded", ChatID: source, Role: "user", Text: decision}); err != nil {
		t.Fatal(err)
	}
	response := serve(t, h, "GET", "/chats/"+source+"/handoff", "")
	var preview handoffs.Preview
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &preview) != nil {
		t.Fatalf("preview failed: %d %s", response.Code, response.Body)
	}
	if !strings.Contains(preview.Context, decision) {
		t.Fatalf("recorded context lost when native transcript was absent (historySource=%s, truncated=%v): %s", preview.HistorySource, preview.Truncated, preview.Context)
	}
}

func TestNativeHandoffEmptyHistoryAndSourceAppend(t *testing.T) {
	h, store, a := newRegistryAPIEnv(t)
	h = registryAuthenticated(h)
	cwd, _ := filepath.EvalSymlinks(t.TempDir())
	path := filepath.Join(os.Getenv("CODEX_HOME"), "sessions", "rollout-test-native-fixture.jsonl")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	header := fmt.Sprintf(`{"type":"session_meta","payload":{"id":"native-fixture","cwd":%q}}`+"\n", cwd)
	if err := os.WriteFile(path, []byte(header), 0600); err != nil {
		t.Fatal(err)
	}
	if err := a.registry.Import(registry.Import{
		Agents:   []registry.Agent{{Record: registry.Record{ID: "source-profile"}, Name: "Source", AgentType: "codex"}, {Record: registry.Record{ID: "target-profile"}, Name: "Target", AgentType: "handoff-target"}},
		Projects: []registry.Project{{Record: registry.Record{ID: "project"}, Name: "App", Path: cwd}},
		Chats:    []registry.Chat{{Record: registry.Record{ID: "source"}, AgentID: "source-profile", ProjectID: "project", Title: "Native", SessionID: "native-fixture"}},
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.AddMessage(session.Message{ID: "discarded", ChatID: "source", Role: "user", Text: "DISCARDED_RECORDED_FUTURE"}); err != nil {
		t.Fatal(err)
	}
	response := serve(t, h, "GET", "/chats/source/handoff", "")
	var preview handoffs.Preview
	if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &preview) != nil {
		t.Fatalf("native empty preview: %d %s", response.Code, response.Body)
	}
	if preview.HistorySource != "native" || strings.Contains(preview.Context, "DISCARDED") || len(preview.Capsule.Turns) != 0 {
		t.Fatalf("native empty context resurrected recorded data: %+v", preview)
	}
	// An external native append must invalidate the exact preview digest before
	// any chat, turn or retry receipt is saved.
	body := header + `{"type":"event_msg","payload":{"type":"user_message","message":"New external correction"}}` + "\n"
	if err := os.WriteFile(path, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	request := handoffs.Request{NewChatID: "destination", RequestID: "review", TargetAgentID: "target-profile", Task: "Review", Context: &preview.Context, PreviewDigest: preview.Digest}
	input, _ := json.Marshal(request)
	response = serve(t, h, "POST", "/chats/source/handoff", string(input))
	if response.Code != 409 || !strings.Contains(response.Body.String(), "handoff_context_changed") {
		t.Fatalf("external append accepted stale preview: %d %s", response.Code, response.Body)
	}
	if _, err := a.registry.Handoff("destination"); err != registry.ErrNotFound || store.ChatExists("destination") {
		t.Fatal("stale preview created a destination")
	}
	request.PreviewDigest = ""
	input, _ = json.Marshal(request)
	response = serve(t, h, "POST", "/chats/source/handoff", string(input))
	if response.Code != 400 {
		t.Fatalf("unbound review accepted: %d %s", response.Code, response.Body)
	}
}
