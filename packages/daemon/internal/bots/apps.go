package bots

import (
	"context"
	"fmt"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/oblien/mindwire/packages/daemon/internal/registry"
)

func (s *Service) appActor(actor registry.Bot, app *registry.AppShortcut, editing bool) (registry.Bot, error) {
	current, err := s.authorize(actor, actor.ID, false)
	if err != nil {
		return current, err
	}
	if actor.WorkspaceID == current.WorkspaceID {
		current.ProjectID = actor.ProjectID
	}
	if app != nil && !current.IsMaster {
		if app.ProjectID != current.ProjectID || editing && app.BotID != current.ID {
			return current, fmt.Errorf("this bot can only manage its own apps; ask the manager bot to manage another bot's app")
		}
	}
	return current, nil
}

func appToolResult(operation string, app registry.AppShortcut) map[string]any {
	return map[string]any{"operation": operation, "mindwireApp": app}
}

func (s *Service) addAppTools(server *mcp.Server, actor registry.Bot) {
	mcp.AddTool(server, &mcp.Tool{Name: "apps_list", Description: "List the user's saved app shortcuts. Manager bots can discover apps across linked computers; other bots see this project's apps. Results carry the owning workspaceId."}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		WorkspaceID string `json:"workspaceId,omitempty"`
	}) (*mcp.CallToolResult, any, error) {
		if out, routed, err := s.routeTool(ctx, actor, "apps_list", in); routed {
			return nil, out, err
		}
		current, err := s.appActor(actor, nil, false)
		if err != nil {
			return nil, nil, err
		}
		apps, err := s.db.Apps()
		visible := []registry.AppShortcut{}
		for _, app := range apps {
			if !app.Archived && (current.IsMaster || app.ProjectID == current.ProjectID) {
				visible = append(visible, app)
			}
		}
		return nil, map[string]any{"apps": visible}, err
	})
	mcp.AddTool(server, &mcp.Tool{Name: "apps_get", Description: "Read a saved app shortcut, startup command and current revision before updating it."}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		WorkspaceID string `json:"workspaceId,omitempty"`
		AppID       string `json:"appId"`
	}) (*mcp.CallToolResult, any, error) {
		if out, routed, err := s.routeTool(ctx, actor, "apps_get", in); routed {
			return nil, out, err
		}
		app, err := s.db.App(in.AppID)
		if err != nil {
			return nil, nil, err
		}
		if _, err = s.appActor(actor, &app, false); err != nil {
			return nil, nil, err
		}
		return nil, app, nil
	})
	mcp.AddTool(server, &mcp.Tool{Name: "apps_register", Description: "Save a completed, working app to the client's application catalog and show an Open card. Supply a short name, icon (an SF Symbol name such as calendar, checkmark.circle, chart.bar, or app.fill; bot palette-character icons also work), and HTTP(S) URL. Use http://127.0.0.1:PORT/path for an app on this computer; Clients can forward its port over their authenticated connection. Optional startupCommand is an idempotent shell script run in the project directory when the user opens an unavailable app. It must start the service and return within 20 seconds; use the existing process/service manager or detach output. healthPath optionally checks a path on that same server. Never include credentials in the URL or command. For a reminder or automation without a web interface, set automation=true and URL empty; opening shows schedules. Registration does not execute the script. Retrying the same project and URL does not create another shortcut."}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		WorkspaceID     string `json:"workspaceId,omitempty"`
		ProjectID       string `json:"projectId,omitempty"`
		Name            string `json:"name"`
		Icon            string `json:"icon,omitempty"`
		URL             string `json:"url"`
		StartupCommand  string `json:"startupCommand,omitempty"`
		HealthPath      string `json:"healthPath,omitempty"`
		StaticDirectory string `json:"staticDirectory,omitempty" jsonschema:"Optional dedicated static output folder inside the project (for example dist), containing index.html and public assets only. Used by the owner client's static hosting adapter."`
		Automation      bool   `json:"automation,omitempty" jsonschema:"True for a reminder/automation without a web interface; URL may be empty and opening shows its schedules."`
	}) (*mcp.CallToolResult, any, error) {
		if out, routed, err := s.routeTool(ctx, actor, "apps_register", in); routed {
			return nil, out, err
		}
		current, err := s.appActor(actor, nil, false)
		if err != nil {
			return nil, nil, err
		}
		if in.ProjectID == "" {
			in.ProjectID = current.ProjectID
		}
		if !current.IsMaster && in.ProjectID != current.ProjectID {
			return nil, nil, fmt.Errorf("apps must belong to this bot's project")
		}
		app := registry.AppShortcut{ProjectID: in.ProjectID, Name: in.Name, Icon: in.Icon, URL: in.URL, StartupCommand: in.StartupCommand, HealthPath: in.HealthPath, Automation: in.Automation}
		app.StaticDirectory = in.StaticDirectory
		if current.ProjectID == app.ProjectID {
			app.BotID = current.ID
		}
		s.mutation.Lock()
		defer s.mutation.Unlock()
		app, err = s.db.RegisterApp(app)
		if err != nil {
			return nil, nil, err
		}
		return nil, appToolResult("registered", app), nil
	})
	mcp.AddTool(server, &mcp.Tool{Name: "apps_update", Description: "Update a saved app's name, icon, link or startup script with expectedRevision from apps_get. Set archived=true to remove the shortcut; its files and service remain intact. Omitted fields stay unchanged."}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		WorkspaceID string `json:"workspaceId,omitempty"`
		AppID       string `json:"appId"`
		registry.AppShortcutPatch
	}) (*mcp.CallToolResult, any, error) {
		if in.PublicURL != nil {
			return nil, nil, fmt.Errorf("public links are recorded by the authenticated owner client after publishing")
		}
		if out, routed, err := s.routeTool(ctx, actor, "apps_update", in); routed {
			return nil, out, err
		}
		app, err := s.db.App(in.AppID)
		if err != nil {
			return nil, nil, err
		}
		if _, err = s.appActor(actor, &app, true); err != nil {
			return nil, nil, err
		}
		s.mutation.Lock()
		defer s.mutation.Unlock()
		app, err = s.db.UpdateApp(in.AppID, in.AppShortcutPatch)
		if err != nil {
			return nil, nil, err
		}
		return nil, appToolResult("updated", app), nil
	})
	mcp.AddTool(server, &mcp.Tool{Name: "apps_request_publish", Description: "Show the owner a native Publish app card. The client selects its hosting adapter: expose the saved app's port on a cloud computer, or export staticDirectory as a hosted page. For a local computer the client offers Cloud setup. This tool does NOT deploy, buy a subscription, or return a public URL; it requests an owner action. Use apps_get afterwards to check the confirmed publicUrl. Never report success before that field is set."}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		WorkspaceID string `json:"workspaceId,omitempty"`
		AppID       string `json:"appId"`
	}) (*mcp.CallToolResult, any, error) {
		if out, routed, err := s.routeTool(ctx, actor, "apps_request_publish", in); routed {
			return nil, out, err
		}
		app, err := s.db.App(in.AppID)
		if err != nil {
			return nil, nil, err
		}
		if _, err = s.appActor(actor, &app, true); err != nil {
			return nil, nil, err
		}
		if app.Archived || app.Automation {
			return nil, nil, fmt.Errorf("only active web apps can be published")
		}
		return nil, map[string]any{"status": "requires_owner_action", "mindwirePublish": map[string]any{"app": app}}, nil
	})
}
