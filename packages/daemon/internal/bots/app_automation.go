package bots

import (
	"context"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/oblien/mindwire/packages/daemon/internal/registry"
)

func (s *Service) appAutomationActor(actor registry.Bot, id string) (registry.AppShortcut, error) {
	app, err := s.db.App(id)
	if err != nil {
		return app, err
	}
	_, err = s.appActor(actor, &app, true)
	return app, err
}

func (s *Service) addAppAutomationTools(server *mcp.Server, actor registry.Bot) {
	if s.apps == nil {
		return
	}
	mcp.AddTool(server, &mcp.Tool{Name: "apps_channels", Description: "List available notification destinations by ID and label, without exposing provider credentials. Reuse these channels when configuring an app's notifications."}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		WorkspaceID string `json:"workspaceId,omitempty"`
	}) (*mcp.CallToolResult, any, error) {
		if out, routed, err := s.routeTool(ctx, actor, "apps_channels", in); routed {
			return nil, out, err
		}
		if _, err := s.appActor(actor, nil, false); err != nil {
			return nil, nil, err
		}
		return nil, map[string]any{"channels": s.apps.Channels()}, nil
	})
	mcp.AddTool(server, &mcp.Tool{Name: "apps_notifications_setup", Description: "Create/reuse an app's send-only notification channel and protected credential file on its computer. Omit channelIds to reuse the configured default notification channel. The result gives a credentialFile path, NEVER a secret. Backend code reads this JSON file (appId,endpoint,token), then POSTs {eventId,title,body} to endpoint with Authorization: Bearer token. Use a unique stable eventId per event, and reuse it on retries. The credential can only notify as this app through its selected destinations. Never copy the token into a chat, source file, URL, git, or browser/frontend code. Explicit rotate=true replaces the app's old credential. Notification delivery must already be configured."}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		WorkspaceID string   `json:"workspaceId,omitempty"`
		AppID       string   `json:"appId"`
		ChannelIDs  []string `json:"channelIds,omitempty"`
		Rotate      bool     `json:"rotate,omitempty"`
	}) (*mcp.CallToolResult, any, error) {
		if out, routed, err := s.routeTool(ctx, actor, "apps_notifications_setup", in); routed {
			return nil, out, err
		}
		if _, err := s.appAutomationActor(actor, in.AppID); err != nil {
			return nil, nil, err
		}
		app, path, err := s.apps.NotificationSetup(in.AppID, in.ChannelIDs, in.Rotate)
		if err != nil {
			return nil, nil, err
		}
		return nil, map[string]any{"app": app, "credentialFile": path, "channelIds": app.ChannelIDs}, nil
	})
	mcp.AddTool(server, &mcp.Tool{Name: "apps_schedules", Description: "List this app's persisted schedules, next run times, revisions and last outcomes. Work runs on its owning computer independently of a client or AI conversation. Inspect errors before claiming a reminder ran."}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		WorkspaceID string `json:"workspaceId,omitempty"`
		AppID       string `json:"appId"`
	}) (*mcp.CallToolResult, any, error) {
		if out, routed, err := s.routeTool(ctx, actor, "apps_schedules", in); routed {
			return nil, out, err
		}
		if _, err := s.appAutomationActor(actor, in.AppID); err != nil {
			return nil, nil, err
		}
		jobs, err := s.db.AppSchedules(in.AppID)
		return nil, map[string]any{"schedules": jobs}, err
	})
	mcp.AddTool(server, &mcp.Tool{Name: "apps_schedule_save", Description: "Save a durable app reminder or recurring background command. Use runAt with an ISO timestamp including UTC/offset for one-time work; intervalSeconds>=60 for intervals; or localTime HH:mm plus an IANA timeZone for calendar recurrence, optionally weekdays 0=Sunday..6=Saturday. Give a notification title/body, a shell command, or both (notify after command succeeds). Commands run in the app's project, must return within 30 seconds, and may read the app's protected notification credential file. For updating, pass id and expectedRevision from apps_schedules. enabled=false pauses. The owning host and its scheduler must be running. Enabling a background command requires owner approval through the requesting run; never approve it yourself. Do not use sleep loops or keep an AI turn open. Existing same-name schedules conflict rather than silently duplicate; read and update them."}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		WorkspaceID string `json:"workspaceId,omitempty"`
		AppID       string `json:"appId"`
		registry.AppScheduleSpec
	}) (*mcp.CallToolResult, any, error) {
		if err := s.approveSchedule(ctx, actor, in.WorkspaceID, in.AppID, in.AppScheduleSpec); err != nil {
			return nil, nil, err
		}
		if out, routed, err := s.routeTool(ctx, actor, "apps_schedule_save", in); routed {
			return nil, out, err
		}
		_, err := s.appAutomationActor(actor, in.AppID)
		if err != nil {
			return nil, nil, err
		}
		job, err := s.apps.SaveSchedule(in.AppID, in.AppScheduleSpec)
		if err != nil {
			return nil, nil, err
		}
		return nil, map[string]any{"schedule": job}, nil
	})
	mcp.AddTool(server, &mcp.Tool{Name: "apps_schedule_delete", Description: "Remove one app schedule when requested by the user. Does not delete the app or its files."}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		WorkspaceID string `json:"workspaceId,omitempty"`
		AppID       string `json:"appId"`
		ScheduleID  string `json:"scheduleId"`
	}) (*mcp.CallToolResult, any, error) {
		if out, routed, err := s.routeTool(ctx, actor, "apps_schedule_delete", in); routed {
			return nil, out, err
		}
		if _, err := s.appAutomationActor(actor, in.AppID); err != nil {
			return nil, nil, err
		}
		if err := s.apps.DeleteSchedule(in.AppID, in.ScheduleID); err != nil {
			return nil, nil, err
		}
		return nil, map[string]bool{"removed": true}, nil
	})
}
