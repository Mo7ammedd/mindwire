package handoffs

import (
	"strings"
	"testing"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
)

func TestCompactionSummaryReachesHandoff(t *testing.T) {
	summary := "Keep the established schema; remaining task: verify the migration rollback."
	messages := []agent.Message{
		{Role: "system", Parts: []agent.Part{{Type: "compaction", Compaction: &agent.CompactionInfo{Summary: summary}}}},
		{Role: "user", Text: "Continue the remaining work"},
		{Role: "assistant", Text: "I will continue."},
	}
	text, truncated := contextText(messages)
	if !strings.Contains(text, summary) {
		t.Fatalf("compacted context was lost (truncated=%v): %s", truncated, text)
	}
}
