package bots

import (
	"context"
	"fmt"
	"strings"

	"github.com/oblien/mindwire/packages/daemon/internal/registry"
)

type approvalRunKey struct{}

// Owner API/SDK callers explicitly request their commands. Native agent calls
// require one owner approval for enabling a background command. Reminder-only
// schedules and pausing need no shell capability. Peer calls reach here only
// after the authenticated source daemon obtained approval in its originating run.
func (s *Service) approveSchedule(ctx context.Context, actor registry.Bot, workspaceID, appID string, spec registry.AppScheduleSpec) error {
	if strings.TrimSpace(spec.Command) == "" || spec.Enabled != nil && !*spec.Enabled {
		return nil
	}
	if len(spec.Command) > 8192 || strings.ContainsRune(spec.Command, 0) || len(spec.Name) > 120 {
		return fmt.Errorf("%w: invalid background command", registry.ErrInvalid)
	}
	current, err := s.appActor(actor, nil, false)
	if err != nil {
		return err
	}
	if strings.HasPrefix(actor.ID, peerActorPrefix) {
		return nil
	}
	if workspaceID == "" || workspaceID == s.db.Identity() {
		if _, err := s.appAutomationActor(actor, appID); err != nil {
			return err
		}
	} else if !current.IsMaster {
		return fmt.Errorf("only manager bots can access linked computers")
	}
	approver, ok := s.runtime.(interface {
		ApproveServiceOperation(context.Context, string, string, string) error
	})
	runID, _ := ctx.Value(approvalRunKey{}).(string)
	if !ok || runID == "" {
		return fmt.Errorf("background commands require approval from an active owner interaction")
	}
	if workspaceID == "" {
		workspaceID = s.db.Identity()
	}
	schedule := spec.RunAt
	if spec.IntervalSeconds > 0 {
		schedule += fmt.Sprintf("; every %d seconds", spec.IntervalSeconds)
	}
	if spec.LocalTime != "" {
		schedule += fmt.Sprintf("; %s %s, weekdays %v", spec.LocalTime, spec.TimeZone, spec.Weekdays)
	}
	detail := fmt.Sprintf("Schedule: %s\nApplication: %s\nComputer: %s\nWhen: %s\n\n%s\n\nThis command runs with the host's permissions and can repeat after this chat closes. You can pause or delete its schedule.", spec.Name, appID, workspaceID, schedule, spec.Command)
	return approver.ApproveServiceOperation(ctx, runID, "Allow this background command?", detail)
}
