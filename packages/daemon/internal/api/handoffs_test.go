package api

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
	"github.com/oblien/mindwire/packages/daemon/internal/handoffs"
	"github.com/oblien/mindwire/packages/daemon/internal/orchestrator"
	"github.com/oblien/mindwire/packages/daemon/internal/registry"
)

func init() {
	agent.Register(handoffTestAdapter{"handoff-source"})
	agent.Register(handoffTestAdapter{"handoff-target"})
}

type handoffTestAdapter struct{ name string }

func (a handoffTestAdapter) ID() string { return a.name }
func (a handoffTestAdapter) Meta() agent.CatalogEntry {
	return agent.CatalogEntry{ID: a.name, Name: a.name}
}
func (handoffTestAdapter) Settings() agent.SettingsSchema        { return agent.SettingsSchema{} }
func (handoffTestAdapter) InstallSteps() []agent.Step            { return nil }
func (handoffTestAdapter) VersionCommand() string                { return "" }
func (handoffTestAdapter) ConfigPath() string                    { return "" }
func (handoffTestAdapter) Notifications() agent.NotificationSpec { return agent.NotificationSpec{} }
func (handoffTestAdapter) Doctor(context.Context) []agent.Check  { return nil }
func (handoffTestAdapter) Capabilities() agent.Capabilities {
	return agent.Capabilities{History: agent.SupportNative}
}
func (handoffTestAdapter) Auth(agent.CredStore) agent.AuthModule { return handoffTestAuth{} }

type handoffTestAuth struct{}

func (handoffTestAuth) Methods() []agent.AuthMethod { return nil }
func (handoffTestAuth) Begin(context.Context, string) (agent.AuthState, error) {
	return agent.AuthState{}, nil
}
func (handoffTestAuth) Step(context.Context, map[string]string) (agent.AuthState, error) {
	return agent.AuthState{}, nil
}
func (handoffTestAuth) Status(context.Context) agent.AuthStatus { return agent.AuthStatus{} }
func (handoffTestAuth) EnvForRun() map[string]string            { return nil }
func (handoffTestAdapter) History(q agent.HistoryQuery) ([]agent.Message, error) {
	if q.SessionID != "source-native" {
		return nil, nil
	}
	return []agent.Message{
		{ID: "goal", Role: "user", Text: "Fix authentication"},
		{ID: "decision", Role: "assistant", Text: "Keep the existing API. Cookie expiry still needs review.", Parts: []agent.Part{
			{Type: "thinking", Text: "hidden reasoning must stay private"},
			{Type: "tool", Tool: &agent.ToolPart{Output: "raw output must stay private", Action: &agent.ToolAction{Files: []agent.FileChange{{Path: "auth.go"}}}}},
		}},
	}, nil
}
func (a handoffTestAdapter) RunStream(ctx context.Context, in agent.TurnInput, emit agent.Emit) (agent.TurnResult, error) {
	if in.Message == "hang" {
		<-ctx.Done()
		return agent.TurnResult{Cancelled: true}, nil
	}
	if in.SessionID == "source-native" {
		return agent.TurnResult{Text: "source session was incorrectly reused", IsError: true}, nil
	}
	emit(agent.Event{Type: agent.EventText, Text: "Reviewed in " + in.CWD})
	return agent.TurnResult{SessionID: "target-native", Text: "Reviewed in " + in.CWD}, nil
}

func TestCrossAgentHandoffHTTP(t *testing.T) {
	h, store, a := newRegistryAPIEnv(t)
	h = registryAuthenticated(h)
	cwd := t.TempDir()
	batch := registry.Import{
		Agents: []registry.Agent{
			{Record: registry.Record{ID: "source-profile"}, Name: "Implementer", AgentType: "handoff-source"},
			{Record: registry.Record{ID: "target-profile"}, Name: "Reviewer", AgentType: "handoff-target"},
		},
		Projects: []registry.Project{{Record: registry.Record{ID: "project"}, Name: "App", Path: cwd}},
		Chats:    []registry.Chat{{Record: registry.Record{ID: "source"}, AgentID: "source-profile", ProjectID: "project", Title: "Fix auth", SessionID: "source-native"}},
	}
	if err := a.registry.Import(batch); err != nil {
		t.Fatal(err)
	}
	previewResp := serve(t, h, "GET", "/chats/source/handoff", "")
	var preview handoffs.Preview
	if previewResp.Code != 200 || json.Unmarshal(previewResp.Body.Bytes(), &preview) != nil {
		t.Fatalf("preview: %d %s", previewResp.Code, previewResp.Body)
	}
	for _, text := range []string{"Fix authentication", "Cookie expiry", "auth.go"} {
		if !strings.Contains(preview.Context, text) {
			t.Fatalf("missing context %q: %s", text, preview.Context)
		}
	}
	if strings.Contains(preview.Context, "must stay private") || preview.HistorySource != "native" || len(store.Messages("source")) != 0 {
		t.Fatal("preview leaked hidden data or modified source")
	}
	if serve(t, h, "GET", "/chats/missing/handoff", "").Code != 404 {
		t.Fatal("unknown source must return 404")
	}
	reviewed := preview.Context + "\nDecisions: preserve compatibility. Open issue: expired cookies."
	request := handoffs.Request{NewChatID: "review", RequestID: "review-request", TargetAgentID: "target-profile", Task: "Review the authentication changes", Context: &reviewed}
	post := func(input handoffs.Request) (int, []byte) {
		body, _ := json.Marshal(input)
		r := serve(t, h, "POST", "/chats/source/handoff?agent=handoff-source", string(body))
		return r.Code, r.Body.Bytes()
	}
	bad := request
	bad.TargetAgentID = "source-profile"
	if code, _ := post(bad); code != 400 {
		t.Fatalf("same harness accepted: %d", code)
	}
	bad.TargetAgentID = "unknown-profile"
	if code, _ := post(bad); code != 400 {
		t.Fatalf("unknown target accepted: %d", code)
	}
	oversized := strings.Repeat("x", handoffs.MaxContextBytes+1)
	bad = request
	bad.Context = &oversized
	if code, _ := post(bad); code != 400 {
		t.Fatalf("oversized context accepted: %d", code)
	}
	sourceAgent, _ := a.sup.Resolve("handoff-source")
	running, err := a.sup.StartTurnChecked(sourceAgent, orchestrator.StartTurnInput{ChatID: "source", Message: "hang", CWD: cwd})
	if err != nil {
		t.Fatal(err)
	}
	if code, _ := post(request); code != 409 {
		t.Fatalf("active source accepted: %d", code)
	}
	a.sup.Cancel(running.ID)
	stoppedBy := time.Now().Add(3 * time.Second)
	for a.sup.Busy("source") {
		if time.Now().After(stoppedBy) {
			t.Fatal("source did not stop")
		}
		time.Sleep(time.Millisecond)
	}
	// Fail the state-file admission write after the registry saves its receipt.
	blocker := filepath.Join(a.registry.Directory(), "state.json.tmp")
	if err := os.Mkdir(blocker, 0700); err != nil {
		t.Fatal(err)
	}
	if code, _ := post(request); code != 409 {
		t.Fatalf("failed admission: %d", code)
	}
	if chat, _, _, err := a.registry.ChatContext("review"); err != nil || chat == nil {
		t.Fatal("prepared handoff was lost")
	}
	if err := os.Remove(blocker); err != nil {
		t.Fatal(err)
	}
	code, body := post(request)
	var result struct {
		handoffs.Result
		Snapshot registry.Snapshot `json:"snapshot"`
	}
	if code != 202 || json.Unmarshal(body, &result) != nil {
		t.Fatalf("start: %d %s", code, body)
	}
	deadline := time.Now().Add(3 * time.Second)
	for {
		run, _ := store.GetRun(result.Run.ID)
		if run.Status != "running" {
			if run.Status != "done" {
				t.Fatalf("handoff failed: %+v", run)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("handoff did not finish")
		}
		time.Sleep(time.Millisecond)
	}
	if store.Session("handoff-source", "source") != "source-native" || store.Session("handoff-target", "review") != "target-native" || store.ChatCWD("review") != cwd {
		t.Fatal("session or cwd isolation failed")
	}
	if len(store.Messages("review")) != 2 || !strings.Contains(store.Messages("review")[0].Text, reviewed) {
		t.Fatal("context did not reach target's normal turn")
	}
	if err := a.registry.RenameChat("review", "Reviewed"); err != nil {
		t.Fatal(err)
	}
	chat, _, _, _ := a.registry.ChatContext("review")
	if chat.HandoffFrom == nil || chat.HandoffFrom.ChatID != "source" || chat.BotID != "" {
		t.Fatalf("link missing or inherited source bot: %+v", chat)
	}
	reopened, err := registry.Open(filepath.Join(a.registry.Directory(), "workspace.db"))
	if err != nil {
		t.Fatal(err)
	}
	persisted, err := reopened.Handoff("review")
	persistedChat, _, _, chatErr := reopened.ChatContext("review")
	_ = reopened.Close()
	if err != nil || chatErr != nil || persisted.Message != store.Messages("review")[0].Text || persistedChat.HandoffFrom == nil {
		t.Fatal("handoff receipt or provenance did not survive reopening")
	}
	// Lost response + source deletion still recovers the original task, not a new run.
	if err := a.registry.Delete("chats", "source", nil, true); err != nil {
		t.Fatal(err)
	}
	code, body = post(request)
	var retry handoffs.Result
	if code != 202 || json.Unmarshal(body, &retry) != nil || retry.Run.ID != result.Run.ID {
		t.Fatalf("retry: %d %s", code, body)
	}
	request.Task = "A different task"
	if code, _ := post(request); code != 409 {
		t.Fatalf("changed receipt accepted: %d", code)
	}
	if err := a.registry.Delete("chats", "review", nil, true); err != nil {
		t.Fatal(err)
	}
	if _, err := a.registry.Handoff("review"); err != registry.ErrNotFound {
		t.Fatalf("deleted conversation retained transfer text: %v", err)
	}
}
