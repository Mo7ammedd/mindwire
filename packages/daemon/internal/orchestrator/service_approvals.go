package orchestrator

import (
	"context"
	"errors"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
	"github.com/oblien/mindwire/packages/daemon/internal/runner"
)

var errServiceApprovalDenied = errors.New("the operation was not approved")
var errServiceRunEnded = errors.New("the requesting run is no longer active")

// ApproveServiceOperation uses the same pending interaction, transcript, push and
// owner-response path as desktop approvals. An agent cannot answer it via tools.
func (s *Supervisor) ApproveServiceOperation(ctx context.Context, runID, title, detail string) error {
	return s.requestServiceApproval(ctx, runID, agent.Interaction{
		ID: "service-" + newID(), Kind: "approval", Title: title, Detail: detail,
		Options:       []agent.Action{{ID: "allow", Label: "Allow"}, {ID: "deny", Label: "Don't allow"}},
		NeedsResponse: true, Meta: map[string]any{"origin": "service"},
	})
}

func (s *Supervisor) requestServiceApproval(ctx context.Context, runID string, interaction agent.Interaction) error {
	response := make(chan agent.InteractionResponse, 1)
	s.mu.Lock()
	emit := s.serviceEmit[runID]
	if emit == nil || s.cancels[runID] == nil {
		s.mu.Unlock()
		return errServiceRunEnded
	}
	if s.serviceReplies[runID] == nil {
		s.serviceReplies[runID] = map[string]chan agent.InteractionResponse{}
	}
	if s.pending[runID] == nil {
		s.pending[runID] = map[string]agent.Interaction{}
	}
	s.pending[runID][interaction.ID] = interaction
	s.serviceReplies[runID][interaction.ID] = response
	s.mu.Unlock()
	emit(agent.Event{Type: agent.EventInteraction, Interaction: &interaction})
	decision := "interrupted"
	defer func() {
		s.mu.Lock()
		delete(s.pending[runID], interaction.ID)
		delete(s.serviceReplies[runID], interaction.ID)
		s.mu.Unlock()
		resolved := interaction
		resolved.NeedsResponse = false
		resolved.Meta = map[string]any{"decision": decision}
		for key, value := range interaction.Meta {
			resolved.Meta[key] = value
		}
		emit(agent.Event{Type: agent.EventInteraction, Interaction: &resolved})
	}()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case reply := <-response:
		decision = reply.Decision
		if decision != "allow" {
			return errServiceApprovalDenied
		}
		return nil
	}
}

func (s *Supervisor) attachServiceEmitter(turn runner.Turn) runner.Turn {
	previous := turn.AttachEmitter
	turn.AttachEmitter = func(emit agent.Emit) func() {
		var detach func()
		if previous != nil {
			detach = previous(emit)
		}
		s.mu.Lock()
		s.serviceEmit[turn.RunID] = emit
		s.mu.Unlock()
		return func() {
			s.mu.Lock()
			delete(s.serviceEmit, turn.RunID)
			delete(s.serviceReplies, turn.RunID)
			s.mu.Unlock()
			if detach != nil {
				detach()
			}
		}
	}
	return turn
}
