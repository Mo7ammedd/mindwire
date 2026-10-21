package mindwire

import (
	"context"
	"errors"
	"testing"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
	"github.com/oblien/mindwire/packages/daemon/internal/registry"
)

type handoffSDKAdapter struct{ fakeAdapter }

func (handoffSDKAdapter) ID() string { return "handoff-sdk-target" }
func (handoffSDKAdapter) Meta() CatalogEntry {
	return CatalogEntry{ID: "handoff-sdk-target", Name: "Reviewer"}
}
func init() { agent.Register(handoffSDKAdapter{}) }

func TestHandoffSDKReturnsTrackedRunAndLinkedSnapshot(t *testing.T) {
	c := newFakeClient(t, nil)
	if c.Health().CrossAgentHandoffVersion != 2 {
		t.Fatal("missing capability")
	}
	if err := c.core.registry.Import(registry.Import{
		Agents: []registry.Agent{
			{Record: registry.Record{ID: "author"}, Name: "Author", AgentType: "fake"},
			{Record: registry.Record{ID: "reviewer"}, Name: "Reviewer", AgentType: "handoff-sdk-target"},
		},
		Projects: []registry.Project{{Record: registry.Record{ID: "project"}, Name: "App", Path: c.core.cwd}},
		Chats:    []registry.Chat{{Record: registry.Record{ID: "source"}, AgentID: "author", ProjectID: "project", Title: "Implement"}},
	}); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	preview, err := c.PreviewHandoff(ctx, "source")
	if err != nil {
		t.Fatal(err)
	}
	stale := HandoffRequest{NewChatID: "stale-review", RequestID: "stale", TargetAgentID: "reviewer", Task: "Review", Context: &preview.Context, PreviewDigest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
	if _, err := c.Handoff(ctx, "source", stale); !errors.Is(err, ErrHandoffContextChanged) {
		t.Fatalf("stale review did not preserve its typed cause: %v", err)
	} else {
		var apiErr *APIError
		if !errors.As(err, &apiErr) || apiErr.Status != 409 {
			t.Fatalf("wrong stale-review status: %v", err)
		}
	}
	request := HandoffRequest{NewChatID: "review", RequestID: "sdk-review", TargetAgentID: "reviewer", Task: "Review implementation", Context: &preview.Context, PreviewDigest: preview.Digest}
	result, err := c.WithAgent("codex").Handoff(ctx, "source", request)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = result.Run.Wait(ctx); err != nil {
		t.Fatal(err)
	}
	if result.Run.Agent() != "handoff-sdk-target" {
		t.Fatal("client default overrode destination")
	}
	retried, err := c.Handoff(ctx, "source", request)
	if err != nil || retried.Run.ID() != result.Run.ID() {
		t.Fatalf("duplicate handoff: %+v %v", retried, err)
	}
	var linked bool
	for _, chat := range result.Snapshot.Chats {
		if chat.ID == "review" && chat.HandoffFrom != nil && chat.HandoffFrom.ChatID == "source" {
			linked = true
		}
	}
	if !linked {
		t.Fatal("snapshot has no source link")
	}
}
