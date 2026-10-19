package mindwire

import (
	"errors"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
)

type integrationSDKAdapter struct{ fakeAdapter }

func (integrationSDKAdapter) ID() string { return "integration-sdk-fixture" }
func (integrationSDKAdapter) Capabilities() Capabilities {
	caps := fakeAdapter{}.Capabilities()
	caps.BotProfiles = true
	return caps
}

func TestIntegrationsEmbeddedSDKPersistenceAndDeferredExecution(t *testing.T) {
	agent.Register(integrationSDKAdapter{})
	dir := t.TempDir()
	options := Options{Agent: "integration-sdk-fixture", CWD: dir, StatePath: filepath.Join(dir, "state.json")}
	c, err := New(options)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if c.Health().IntegrationsVersion < 1 {
		t.Fatal("integration capability missing")
	}
	if _, err := c.Workspace.Agents.Put("agent", WorkspaceAgent{Name: "Agent", AgentType: options.Agent}, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Workspace.Projects.Put("project", WorkspaceProject{Name: "Project", Path: dir}, nil); err != nil {
		t.Fatal(err)
	}
	bot, err := c.Bots.Create(Bot{AgentID: "agent", ProjectID: "project", Name: "Assistant"})
	if err != nil {
		t.Fatal(err)
	}
	connection, err := c.Integrations.Create(IntegrationSpec{Name: "Telegram", Provider: "telegram", Mode: "chat", Enabled: true, BotID: bot.Bot.ID, ChannelIDs: []string{"100"}, Credentials: &IntegrationCredentials{BotToken: "test-token", WebhookSecret: "test-webhook-secret"}})
	if err != nil {
		t.Fatal(err)
	}
	other := c.WithAgent("codex")
	shared, err := other.Integrations.Get(connection.ID)
	if err != nil || shared.ID != connection.ID {
		t.Fatal("harness view lost shared integration", err)
	}
	spec := shared.Spec
	spec.ExpectedRevision = shared.Revision
	spec.Name = "Renamed Telegram"
	updated, err := other.Integrations.Update(shared.ID, spec)
	if err != nil || !updated.HasCredentials {
		t.Fatal("update lost credentials", err)
	}
	_, err = c.Integrations.Update(shared.ID, spec)
	var conflict *APIError
	if !errors.As(err, &conflict) || conflict.Status != 409 {
		t.Fatal("revision conflict lacks SDK error semantics", err)
	}
	r := httptest.NewRequest("POST", connection.WebhookPath, strings.NewReader(`{"update_id":1,"message":{"text":"hello","from":{"id":200},"chat":{"id":100}}}`))
	r.SetPathValue("id", connection.ID)
	r.Header.Set("X-Telegram-Bot-Api-Secret-Token", "test-webhook-secret")
	w := httptest.NewRecorder()
	c.Integrations.Webhook(w, r)
	if w.Code != 200 {
		t.Fatal("webhook failed", w.Body.String())
	}
	events, err := c.Integrations.Events(connection.ID)
	if err != nil || len(events) != 1 || events[0].State != "queued" {
		t.Fatal("embedded host executed without opt-in", events, err)
	}
	if err := c.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := New(options)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if saved, err := reopened.Integrations.Get(connection.ID); err != nil || saved.Name != "Renamed Telegram" || !saved.HasCredentials {
		t.Fatal("restart lost connection", err)
	}
	if events, err := reopened.Integrations.Events(connection.ID); err != nil || len(events) != 1 || events[0].State != "queued" {
		t.Fatal("restart lost pending event", events, err)
	}
}
