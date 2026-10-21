package handoffs

import (
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
)

func TestContextIsBoundedVisibleAndKeepsRecentWork(t *testing.T) {
	messages := []agent.Message{{Role: "user", Text: "Original task"}}
	for i := 0; i < 50; i++ {
		messages = append(messages, agent.Message{Role: "assistant", Text: strings.Repeat("界", 6000)})
	}
	messages = append(messages, agent.Message{Role: "assistant", Text: "Latest decision: keep the public API. Remaining issue: retry failures."})
	text, truncated := contextText(messages)
	if !truncated || len(text) > MaxContextBytes || !utf8.ValidString(text) || !strings.Contains(text, "Original task") || !strings.Contains(text, "Latest decision") || !strings.Contains(text, "Context is partial") {
		t.Fatalf("bad bounded context: bytes=%d truncated=%v valid=%v", len(text), truncated, utf8.ValidString(text))
	}
	text, truncated = contextText([]agent.Message{{Role: "assistant", Parts: []agent.Part{{Type: "thinking", Text: "private"}, {Type: "text", Text: "Visible answer"}}}})
	if truncated || strings.Contains(text, "private") || !strings.Contains(text, "Visible answer") {
		t.Fatal("visible parts were not preserved")
	}
}
