package bots

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/oblien/mindwire/packages/daemon/internal/registry"
)

func (s *Service) addKnowledgeTools(server *mcp.Server, actor registry.Bot) {
	mcp.AddTool(server, &mcp.Tool{Name: "memory_read", Description: "Read the bot's latest durable memory and revision before merging an update. Other bots are accessible only to Mindwire."}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		WorkspaceID string `json:"workspaceId,omitempty" jsonschema:"Destination computer workspaceId from discovery; omit for this computer."`

		BotID string `json:"botId,omitempty"`
	}) (*mcp.CallToolResult, any, error) {
		if out, routed, err := s.routeTool(ctx, actor, "memory_read", in); routed {
			return nil, out, err
		}
		bot, err := s.authorize(actor, in.BotID, false)
		if err != nil {
			return nil, nil, err
		}
		return nil, map[string]any{"botId": bot.ID, "memory": bot.Memory, "revision": bot.Revision}, nil
	})
	mcp.AddTool(server, &mcp.Tool{Name: "memory_update", Description: "Save durable facts or preferences established by the user. Merge with memory_read first and preserve unrelated facts. This replaces only memory, never instructions or documents. Pass the latest expectedRevision."}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		WorkspaceID string `json:"workspaceId,omitempty" jsonschema:"Destination computer workspaceId from discovery; omit for this computer."`

		BotID            string `json:"botId,omitempty"`
		Memory           string `json:"memory"`
		ExpectedRevision int64  `json:"expectedRevision"`
	}) (*mcp.CallToolResult, any, error) {
		if out, routed, err := s.routeTool(ctx, actor, "memory_update", in); routed {
			return nil, out, err
		}
		s.mutation.Lock()
		defer s.mutation.Unlock()
		bot, err := s.authorize(actor, in.BotID, false)
		if err != nil {
			return nil, nil, err
		}
		bot, err = s.db.UpdateBot(bot.ID, registry.BotPatch{ExpectedRevision: in.ExpectedRevision, Memory: &in.Memory})
		return botResult("memory_updated", bot, err)
	})
	mcp.AddTool(server, &mcp.Tool{Name: "knowledge_search", Description: "Search this bot's saved documents for relevant passages. Returns source IDs/titles and bounded excerpts. Mindwire can specify another botId when managing that bot."}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		WorkspaceID string `json:"workspaceId,omitempty" jsonschema:"Destination computer workspaceId from discovery; omit for this computer."`

		BotID string `json:"botId,omitempty"`
		Query string `json:"query"`
	}) (*mcp.CallToolResult, any, error) {
		if out, routed, err := s.routeTool(ctx, actor, "knowledge_search", in); routed {
			return nil, out, err
		}
		bot, err := s.authorize(actor, in.BotID, false)
		if err != nil {
			return nil, nil, err
		}
		type match struct {
			SourceID string `json:"sourceId"`
			Title    string `json:"title"`
			Text     string `json:"text"`
			score    int
		}
		matches := []match{}
		terms := strings.Fields(strings.ToLower(in.Query))
		if len(terms) > 32 {
			terms = terms[:32]
		}
		for _, source := range bot.Knowledge {
			paragraphs := strings.Split(source.Content, "\n\n")
			for _, paragraph := range paragraphs {
				// Fixed-size rune chunks bound results even for a document with no paragraph breaks.
				runes := []rune(paragraph)
				for start := 0; start < len(runes); start += 1200 {
					end := min(start+1200, len(runes))
					text := string(runes[start:end])
					lower := strings.ToLower(source.Title + " " + text)
					score := 0
					for _, term := range terms {
						score += strings.Count(lower, term)
					}
					if score > 0 || len(terms) == 0 {
						matches = append(matches, match{source.ID, source.Title, text, score})
					}
				}
			}
		}
		sort.SliceStable(matches, func(i, j int) bool { return matches[i].score > matches[j].score })
		if len(matches) > 8 {
			matches = matches[:8]
		}
		return nil, map[string]any{"botId": bot.ID, "matches": matches, "sourceCount": len(bot.Knowledge)}, nil
	})
	mcp.AddTool(server, &mcp.Tool{Name: "knowledge_read", Description: "Read one saved knowledge document in bounded pages. offset and limit count Unicode characters; default limit is 6000, maximum 12000. Use nextOffset to continue."}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		WorkspaceID string `json:"workspaceId,omitempty" jsonschema:"Destination computer workspaceId from discovery; omit for this computer."`

		BotID    string `json:"botId,omitempty"`
		SourceID string `json:"sourceId"`
		Offset   int    `json:"offset,omitempty"`
		Limit    int    `json:"limit,omitempty"`
	}) (*mcp.CallToolResult, any, error) {
		if out, routed, err := s.routeTool(ctx, actor, "knowledge_read", in); routed {
			return nil, out, err
		}
		bot, err := s.authorize(actor, in.BotID, false)
		if err != nil {
			return nil, nil, err
		}
		if in.Offset < 0 || in.Limit < 0 || in.Limit > 12000 {
			return nil, nil, fmt.Errorf("invalid document page")
		}
		if in.Limit == 0 {
			in.Limit = 6000
		}
		for _, source := range bot.Knowledge {
			if source.ID == in.SourceID {
				runes := []rune(source.Content)
				start := min(in.Offset, len(runes))
				end := min(start+in.Limit, len(runes))
				return nil, map[string]any{"sourceId": source.ID, "title": source.Title, "text": string(runes[start:end]), "nextOffset": end, "hasMore": end < len(runes)}, nil
			}
		}
		return nil, nil, fmt.Errorf("knowledge source not found")
	})
	if !actor.IsMaster {
		return
	}
	mcp.AddTool(server, &mcp.Tool{Name: "knowledge_put", Description: "Save document text or a grounded summary as a durable knowledge source for a bot. Use extracted content from user-provided documents, never invented content. sourceId updates an existing source; omit it to derive a stable ID from the title. Pass the bot's latest expectedRevision."}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		WorkspaceID string `json:"workspaceId,omitempty" jsonschema:"Destination computer workspaceId from discovery; omit for this computer."`

		BotID            string `json:"botId"`
		SourceID         string `json:"sourceId,omitempty"`
		Title            string `json:"title"`
		Content          string `json:"content"`
		ExpectedRevision int64  `json:"expectedRevision"`
	}) (*mcp.CallToolResult, any, error) {
		if out, routed, err := s.routeTool(ctx, actor, "knowledge_put", in); routed {
			return nil, out, err
		}
		s.mutation.Lock()
		defer s.mutation.Unlock()
		bot, err := s.authorize(actor, in.BotID, true)
		if err != nil {
			return nil, nil, err
		}
		if in.SourceID == "" {
			in.SourceID = "source-" + registry.SyncKey(bot.ID, strings.ToLower(strings.TrimSpace(in.Title)))[:24]
		}
		source := registry.BotKnowledge{ID: in.SourceID, Title: in.Title, Content: in.Content}
		found := false
		for i := range bot.Knowledge {
			if bot.Knowledge[i].ID == source.ID {
				bot.Knowledge[i] = source
				found = true
				break
			}
		}
		if !found {
			bot.Knowledge = append(bot.Knowledge, source)
		}
		bot, err = s.db.UpdateBot(bot.ID, registry.BotPatch{ExpectedRevision: in.ExpectedRevision, Knowledge: &bot.Knowledge})
		return botResult("knowledge_updated", bot, err)
	})
	mcp.AddTool(server, &mcp.Tool{Name: "knowledge_remove", Description: "Remove one knowledge source only when the user requests it. Other sources, memory and chats stay intact. Requires the latest expectedRevision."}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		WorkspaceID string `json:"workspaceId,omitempty" jsonschema:"Destination computer workspaceId from discovery; omit for this computer."`

		BotID            string `json:"botId"`
		SourceID         string `json:"sourceId"`
		ExpectedRevision int64  `json:"expectedRevision"`
	}) (*mcp.CallToolResult, any, error) {
		if out, routed, err := s.routeTool(ctx, actor, "knowledge_remove", in); routed {
			return nil, out, err
		}
		s.mutation.Lock()
		defer s.mutation.Unlock()
		bot, err := s.authorize(actor, in.BotID, true)
		if err != nil {
			return nil, nil, err
		}
		kept := []registry.BotKnowledge{}
		for _, source := range bot.Knowledge {
			if source.ID != in.SourceID {
				kept = append(kept, source)
			}
		}
		bot, err = s.db.UpdateBot(bot.ID, registry.BotPatch{ExpectedRevision: in.ExpectedRevision, Knowledge: &kept})
		return botResult("knowledge_removed", bot, err)
	})
}
