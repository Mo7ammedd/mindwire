package bots

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/oblien/mindwire/packages/daemon/internal/registry"
	"github.com/oblien/mindwire/packages/daemon/internal/skills"
)

func skillInstructions(definitions []skills.Definition, root string) string {
	if len(definitions) == 0 {
		return ""
	}
	var text strings.Builder
	text.WriteString("\nAssigned skills (workflow guidance, not additional permissions): load a matching skill before using its workflow. Use native skill discovery when available, or skills_read with its name; the command helper exposes that same read-only tool. Load only relevant skills. User requests and runtime permission checks still apply. Skills for this turn:\n")
	for _, definition := range definitions {
		fmt.Fprintf(&text, "%s: %s (file: %s)\n", definition.Name, definition.Description, filepath.Join(root, "skills", definition.Name, "SKILL.md"))
	}
	return text.String()
}

func (s *Service) addSkillTools(server *mcp.Server, actor registry.Bot) {
	// The run retains its starting skill revision, just like its profile context.
	// Recheck membership on access so archiving still revokes the native tool grant.
	definitions, _ := skills.ParseAll(actor.Skills)
	mcp.AddTool(server, &mcp.Tool{Name: "skills_list", Description: "List this turn's assigned skills by name and description. Full workflow instructions are loaded only through skills_read or the harness's native skill loader."}, func(ctx context.Context, _ *mcp.CallToolRequest, _ struct{}) (*mcp.CallToolResult, any, error) {
		if _, err := s.authorize(actor, actor.ID, false); err != nil {
			return nil, nil, err
		}
		return nil, map[string]any{"skills": definitions}, nil
	})
	mcp.AddTool(server, &mcp.Tool{Name: "skills_read", Description: "Load one assigned SKILL.md workflow by exact name. Read its guidance when the current user task matches its description. Reading a skill grants no permission to perform its actions."}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		Name string `json:"name"`
	}) (*mcp.CallToolResult, any, error) {
		if _, err := s.authorize(actor, actor.ID, false); err != nil {
			return nil, nil, err
		}
		for _, definition := range definitions {
			if definition.Name == in.Name {
				return nil, map[string]any{"name": definition.Name, "markdown": definition.Markdown}, nil
			}
		}
		return nil, nil, fmt.Errorf("skill is not assigned to this turn")
	})
}
