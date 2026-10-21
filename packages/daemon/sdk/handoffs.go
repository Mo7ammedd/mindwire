package mindwire

import (
	"context"

	"github.com/oblien/mindwire/packages/daemon/internal/handoffs"
	"github.com/oblien/mindwire/packages/daemon/internal/registry"
)

type HandoffRequest = handoffs.Request
type HandoffPreview = handoffs.Preview
type HandoffOrigin = registry.HandoffOrigin

type HandoffResult struct {
	ChatID   string
	Run      *Run
	Snapshot WorkspaceSnapshot
}

// PreviewHandoff reads visible context without running either agent. Review or
// edit Context before passing it to Handoff; nil Context builds it at admission.
func (c *Client) PreviewHandoff(ctx context.Context, chatID string) (HandoffPreview, error) {
	preview, err := c.handoffService().Preview(ctx, chatID)
	return preview, workspaceError("PreviewHandoff", err)
}

// Handoff starts a fresh session on another saved agent in the same project.
// Reuse NewChatID, RequestID and the identical payload after a lost response.
func (c *Client) Handoff(ctx context.Context, sourceChatID string, request HandoffRequest) (*HandoffResult, error) {
	result, err := c.handoffService().Start(ctx, sourceChatID, request)
	if err != nil {
		return nil, workspaceError("Handoff", err)
	}
	c.core.track(result.Run.ID)
	snapshot, err := c.core.registry.Snapshot(nil)
	if err != nil {
		return nil, workspaceError("Handoff", err)
	}
	return &HandoffResult{ChatID: result.ChatID, Run: &Run{core: c.core, data: result.Run}, Snapshot: snapshot}, nil
}

func (c *Client) handoffService() *handoffs.Service {
	return &handoffs.Service{Registry: c.core.registry, Store: c.core.store, Supervisor: c.core.sup, Mutation: &c.core.registryMu}
}
