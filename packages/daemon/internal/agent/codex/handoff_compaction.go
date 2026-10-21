package codex

import (
	"encoding/json"
	"strings"
)

// Some Codex versions persist the readable continuation only in replacement
// history. Extract visible message content, never reasoning, encrypted state,
// developer/system instructions, or tool call/output items.
func compactedReplacementText(items []json.RawMessage) string {
	var text []string
	for _, raw := range items {
		var item struct {
			Type    string          `json:"type"`
			Role    string          `json:"role"`
			Content json.RawMessage `json:"content"`
		}
		if json.Unmarshal(raw, &item) != nil || item.Type != "message" || item.Role != "user" && item.Role != "assistant" {
			continue
		}
		var literal string
		if json.Unmarshal(item.Content, &literal) == nil {
			if strings.TrimSpace(literal) != "" {
				text = append(text, literal)
			}
			continue
		}
		var parts []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		}
		if json.Unmarshal(item.Content, &parts) != nil {
			continue
		}
		for _, part := range parts {
			if (part.Type == "input_text" || part.Type == "output_text" || part.Type == "text") && part.Text != "" {
				text = append(text, part.Text)
			}
		}
	}
	return strings.TrimSpace(strings.Join(text, "\n"))
}
