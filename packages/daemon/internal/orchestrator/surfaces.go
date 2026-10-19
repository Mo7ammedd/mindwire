package orchestrator

import (
	"context"
	"errors"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
	"github.com/oblien/mindwire/packages/daemon/internal/runner"
	"github.com/oblien/mindwire/packages/daemon/internal/surface"
)

func (s *Supervisor) SetSurfaces(service *surface.Service) {
	s.mu.Lock()
	s.surfaces = service
	s.mu.Unlock()
	service.SetApproval(s.approveDesktop)
}

// Service approvals use the same reducer, notification, response validation and
// saved transcript as native harness approvals. They never enter CLI ingress.
func (s *Supervisor) approveDesktop(ctx context.Context, actor surface.Actor, title string) error {
	id := "desktop-" + newID()
	interaction := agent.Interaction{ID: id, Kind: "approval", Title: title,
		Detail:        "The agent can see this desktop, type, use its clipboard and click until this session ends. You can take control from Desktop at any time.",
		Options:       []agent.Action{{ID: "allow", Label: "Allow for this session"}, {ID: "deny", Label: "Don't allow"}},
		NeedsResponse: true, Meta: map[string]any{"origin": "surface", "surfaceId": "desktop"}}
	err := s.requestServiceApproval(ctx, actor.RunID, interaction)
	if errors.Is(err, errServiceRunEnded) {
		return &surface.Error{Code: "run_ended", Message: "This agent run is no longer active."}
	}
	if errors.Is(err, errServiceApprovalDenied) {
		return &surface.Error{Code: "denied", Message: "Desktop access was not approved."}
	}
	return err
}

func (s *Supervisor) desktopTurn(ctx context.Context, a *Agent, turn runner.Turn) (runner.Turn, func(), error) {
	s.mu.Lock()
	service := s.surfaces
	s.mu.Unlock()
	if service == nil {
		return turn, func() {}, nil
	}
	actor := surface.Actor{Kind: "agent", Name: a.ID(), RunID: turn.RunID, ChatID: turn.ChatID, CWD: turn.CWD}
	overlay, env, cleanup, err := service.BindRun(ctx, actor, a.ID(), turn.Options.MCPServers)
	if err != nil {
		return turn, func() {}, err
	}
	settings, err := surface.PermissionSettings(a.ID(), turn.Options.ClaudeSettings)
	if err != nil {
		cleanup()
		return turn, func() {}, err
	}
	turn.Options.MCPServers = overlay
	turn.Options.ClaudeSettings = settings
	if turn.Environment == nil {
		turn.Environment = map[string]string{}
	}
	for key, value := range env {
		turn.Environment[key] = value
	}
	if env["MINDWIRE_DESKTOP_HELPER"] != "" {
		turn.Message += surface.FallbackInstructions()
	}
	return turn, cleanup, nil
}
