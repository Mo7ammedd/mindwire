package mindwire

import (
	"context"
	"errors"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"

	"github.com/oblien/mindwire/packages/daemon/internal/handoffs"
	"github.com/oblien/mindwire/packages/daemon/internal/registry"
)

// ErrHandoffContextChanged means no destination was admitted. Refresh and review
// the source before retrying; use errors.Is to distinguish it from a lost response.
var ErrHandoffContextChanged = handoffs.ErrPreviewChanged

func handoffSDKError(op string, err error) error {
	if errors.Is(err, ErrHandoffContextChanged) {
		return &APIError{Message: err.Error(), Status: 409, Op: op, Cause: err}
	}
	return workspaceError(op, err)
}

type HandoffRequest = handoffs.Request
type HandoffPreview = handoffs.Preview
type HandoffOrigin = registry.HandoffOrigin
type HandoffContext = agent.HandoffContext
type HandoffSource = agent.HandoffSource
type HandoffSummary = agent.HandoffSummary
type HandoffTurn = agent.HandoffTurn
type HandoffLoss = agent.HandoffLoss
type HandoffTool = agent.HandoffTool
type HandoffArtifact = agent.HandoffArtifact

type HandoffResult struct {
	ChatID   string
	Run      *Run
	Snapshot WorkspaceSnapshot
}

// PreviewHandoff exports portable context without running either agent. Return
// Digest as PreviewDigest with reviewed Context; nil Context captures at admission.
func (c *Client) PreviewHandoff(ctx context.Context, chatID string) (HandoffPreview, error) {
	preview, err := c.handoffService().Preview(ctx, chatID)
	return preview, handoffSDKError("PreviewHandoff", err)
}

// Handoff starts a fresh session on another saved agent in the same project.
// Reuse NewChatID, RequestID and the identical payload after a lost response.
func (c *Client) Handoff(ctx context.Context, sourceChatID string, request HandoffRequest) (*HandoffResult, error) {
	result, err := c.handoffService().Start(ctx, sourceChatID, request)
	if err != nil {
		return nil, handoffSDKError("Handoff", err)
	}
	c.core.track(result.Run.ID)
	snapshot, err := c.core.registry.Snapshot(nil)
	if err != nil {
		return nil, handoffSDKError("Handoff", err)
	}
	return &HandoffResult{ChatID: result.ChatID, Run: &Run{core: c.core, data: result.Run}, Snapshot: snapshot}, nil
}

func (c *Client) handoffService() *handoffs.Service {
	return &handoffs.Service{Registry: c.core.registry, Store: c.core.store, Supervisor: c.core.sup, Mutation: &c.core.registryMu}
}
