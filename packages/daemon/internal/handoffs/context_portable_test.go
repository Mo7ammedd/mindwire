package handoffs

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
)

func testSource() agent.HandoffSource {
	return agent.HandoffSource{AgentType: "codex", ChatID: "source", Revision: "revision", History: "native"}
}

func TestPortableContextKeepsLatestCompactionAndPostBoundaryCorrections(t *testing.T) {
	messages := []agent.Message{
		{ID: "goal", Role: "user", Text: "Original request"},
		{Role: "assistant", Text: "Obsolete proposal: change the API"},
		{ID: "old-summary", Role: "system", Parts: []agent.Part{{Type: "compaction", Compaction: &agent.CompactionInfo{Summary: "Obsolete summary"}}}},
		{Role: "assistant", Text: "Work before the newest summary"},
		{ID: "current-summary", Role: "system", Parts: []agent.Part{{Type: "compaction", Compaction: &agent.CompactionInfo{Summary: "Preserve the API. Completed: auth fix. Pending: rollback test."}}}},
		{ID: "correction", Role: "user", Text: "Do not deploy. Test on the staging branch."},
		{Role: "assistant", Parts: []agent.Part{{Type: "thinking", Text: "PRIVATE_REASONING"}, {Type: "text", Text: "I will test staging."}}},
	}
	c := normalizeContext(testSource(), messages, nil)
	data, _ := json.Marshal(c)
	if c.Summary == nil || c.Summary.MessageID != "current-summary" || len(c.Turns) != 2 || c.Turns[0].Role != "user" || !strings.Contains(c.Turns[0].Text, "Do not deploy") {
		t.Fatalf("lost compacted state or steering: %s", data)
	}
	for _, forbidden := range []string{"Obsolete", "Work before", "PRIVATE_REASONING"} {
		if strings.Contains(string(data), forbidden) {
			t.Fatalf("superseded/private data retained: %s", data)
		}
	}
	if len(c.Losses) != 0 {
		t.Fatalf("ordinary supported compaction reported as lost: %+v", c.Losses)
	}
}

func TestPortableContextReportsOpaqueCompactionWithoutInventingEmptyState(t *testing.T) {
	c := normalizeContext(testSource(), []agent.Message{
		{Role: "user", Text: "Keep this constraint"},
		{Role: "system", Parts: []agent.Part{{Type: "compaction", Compaction: &agent.CompactionInfo{}}}},
		{Role: "assistant", Text: "Latest work"},
	}, nil)
	if len(c.Losses) != 1 || c.Losses[0].Code != "compaction_summary_unavailable" || len(c.Turns) != 2 || c.Turns[0].Text != "Keep this constraint" {
		t.Fatalf("opaque compaction silently lost: %+v", c)
	}
}

func TestPortableContextOrdersSteeringAndToolOutcomesWithoutReplayingInputs(t *testing.T) {
	exit := 1
	messages := []agent.Message{{ID: "turn", Role: "assistant", Text: "Before\nAfter", Parts: []agent.Part{
		{Type: "text", Text: "Before"},
		{Type: "tool", Tool: &agent.ToolPart{Input: json.RawMessage(`{"SECRET_INPUT":"never transfer"}`), Output: "failure", Action: &agent.ToolAction{Kind: agent.KindShell, Title: "Test suite", Shell: &agent.ShellCommand{Command: "go test ./...", Stdout: "regression failed", ExitCode: &exit}}}},
		{Type: "input", Input: &agent.UserInput{ID: "steer", Text: "Stop changing public types", Status: "accepted"}},
		{Type: "input", Input: &agent.UserInput{ID: "cancelled", Text: "CANCELLED_INPUT", Status: "cancelled"}},
		{Type: "text", Text: "After"},
		{Type: "thinking", Text: "PRIVATE_THOUGHT"},
	}}}
	c := normalizeContext(testSource(), messages, nil)
	if len(c.Turns) != 4 || len(c.Turns[1].Tools) != 1 || c.Turns[1].Tools[0].Status != "failed" || c.Turns[2].Role != "user" || c.Turns[2].Text != "Stop changing public types" || c.Turns[3].Text != "After" {
		t.Fatalf("wrong event order: %+v", c.Turns)
	}
	data, _ := json.Marshal(c)
	for _, secret := range []string{"SECRET_INPUT", "PRIVATE_THOUGHT", "CANCELLED_INPUT"} {
		if strings.Contains(string(data), secret) {
			t.Fatalf("excluded content leaked: %s", data)
		}
	}
	if c.Turns[1].Tools[0].ExitCode == nil || *c.Turns[1].Tools[0].ExitCode != 1 || c.Turns[1].Tools[0].Output != "regression failed" {
		t.Fatal("lost observed test result")
	}
}

func TestPortableContextUnknownResultsRemainUnknownAndArtifactsHaveReferences(t *testing.T) {
	c := normalizeContext(testSource(), []agent.Message{{Role: "assistant", Parts: []agent.Part{{Type: "tool", Tool: &agent.ToolPart{Action: &agent.ToolAction{Kind: agent.KindFileEdit, Files: []agent.FileChange{{Path: "auth.go", Op: "edit", Diff: "PRIVATE_DIFF"}}}}}}},
		{Role: "user", Attachments: []agent.Attachment{{Name: "mock.png", Mime: "image/png", Path: "/project/mock.png"}, {Name: "inline.png", Mime: "image/png", Data: []byte("PRIVATE_BINARY")}}},
	}, nil)
	if c.Turns[0].Tools[0].Status != "unknown" || c.Turns[0].Tools[0].ExitCode != nil || c.Turns[0].Tools[0].Files[0].Diff != "" {
		t.Fatal("invented success or retained raw edit")
	}
	if len(c.Turns[1].Artifacts) != 2 || !c.Turns[1].Artifacts[0].Available || c.Turns[1].Artifacts[1].Available || len(c.Losses) == 0 {
		t.Fatal("artifact availability not explicit")
	}
	data, _ := json.Marshal(c)
	if strings.Contains(string(data), "PRIVATE_") {
		t.Fatal("raw binary/edit entered context")
	}
}

func TestPortableContextUsesBudgetInsteadOfTwelveMessageLimit(t *testing.T) {
	var messages []agent.Message
	for i := 0; i < 30; i++ {
		messages = append(messages, agent.Message{Role: "user", Text: "Small instruction"})
	}
	c := normalizeContext(testSource(), messages, nil)
	if len(c.Turns) != 30 || len(c.Losses) != 0 {
		t.Fatalf("unnecessary message limit: %+v", c)
	}
	for i := 0; i < 80; i++ {
		messages = append(messages, agent.Message{Role: "assistant", Text: strings.Repeat("界\x00", 9000)})
	}
	messages = append(messages, agent.Message{Role: "user", Text: "LATEST_CORRECTION: keep user data"})
	c = normalizeContext(testSource(), messages, nil)
	if err := agent.ValidateHandoffContext(c); err != nil {
		t.Fatal(err)
	}
	rendered := agent.RenderHandoffContext(c)
	if !utf8.ValidString(rendered) || len(rendered) > MaxContextBytes || len(c.Losses) == 0 || !strings.Contains(rendered, "LATEST_CORRECTION") {
		t.Fatal("invalid or silently truncated context")
	}
}

func TestPortableContextTargetEncodingRoundTripsAndReviewedEditsRemoveOriginals(t *testing.T) {
	c := normalizeContext(testSource(), []agent.Message{{Role: "user", Text: "ORIGINAL_PRIVATE_TEXT"}}, nil)
	c = reviewedContext(c.Source, "Only this reviewed context", nil)
	for _, target := range []string{"codex", "claude-code", "opencode", "grok"} {
		input, err := agent.EncodeHandoffPrompt(c, "Review", target, target+"/test-v1")
		if err != nil {
			t.Fatal(err)
		}
		decoded, err := agent.DecodeHandoffPrompt(input.Message)
		if err != nil || !reflect.DeepEqual(decoded.Context, c) || strings.Contains(input.Message, "ORIGINAL_PRIVATE_TEXT") {
			t.Fatalf("invalid target payload %s: %+v %v", target, decoded, err)
		}
		if _, err := agent.DecodeHandoffPrompt(input.Message + " {}"); err == nil {
			t.Fatal("trailing envelope accepted")
		}
	}
	c.Version = 999
	if _, err := agent.EncodeHandoffPrompt(c, "Review", "codex", "test"); err == nil {
		t.Fatal("unknown context version accepted")
	}
}

func TestPortableContextPartialToolOutputIsNotProofOfSuccess(t *testing.T) {
	c := normalizeContext(testSource(), []agent.Message{{Role: "assistant", Parts: []agent.Part{
		{Type: "tool", Tool: &agent.ToolPart{Output: "partial result", Status: "in_progress", Action: &agent.ToolAction{Kind: agent.KindShell, Shell: &agent.ShellCommand{Command: "go test", Stdout: "still running"}}}},
		{Type: "tool", Tool: &agent.ToolPart{Status: "completed", Action: &agent.ToolAction{Kind: agent.KindFileEdit, Files: []agent.FileChange{{Path: "auth.go", Op: "edit"}}}}},
	}}}, nil)
	if c.Turns[0].Tools[0].Status != "unknown" || c.Turns[1].Tools[0].Status != "completed" {
		t.Fatalf("invented or lost success: %+v", c.Turns)
	}
}
