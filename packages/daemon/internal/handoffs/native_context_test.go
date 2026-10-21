package handoffs

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
	_ "github.com/oblien/mindwire/packages/daemon/internal/agent/claude"
	_ "github.com/oblien/mindwire/packages/daemon/internal/agent/codex"
	_ "github.com/oblien/mindwire/packages/daemon/internal/agent/grok"
	_ "github.com/oblien/mindwire/packages/daemon/internal/agent/opencode"
)

func nativeAdapter(t *testing.T, id string) agent.Adapter {
	t.Helper()
	for _, a := range agent.All() {
		if a.ID() == id {
			return a
		}
	}
	t.Fatalf("missing adapter %s", id)
	return nil
}

func TestNativeHandoffContextAcrossAgents(t *testing.T) {
	const summary = "Keep the public API. The migration rollback is still failing."
	fixtures := map[string]string{
		"codex": `{"type":"session_meta","payload":{"id":"fixture","cwd":"/repo"}}
{"type":"event_msg","payload":{"type":"task_started","turn_id":"old"}}
{"type":"event_msg","payload":{"type":"user_message","message":"Fix checkout"}}
{"type":"event_msg","payload":{"type":"agent_message","message":"Superseded proposal: delete the API"}}
{"type":"compacted","payload":{"message":"Keep the public API. The migration rollback is still failing."}}
{"type":"event_msg","payload":{"type":"task_started","turn_id":"new"}}
{"type":"event_msg","payload":{"type":"user_message","message":"Correction: do not change billing periods"}}
{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"cmd","command":"go test ./billing","status":"completed","aggregated_output":"rollback failed","exit_code":1}}}
{"type":"event_msg","payload":{"type":"task_complete"}}
`,
		"claude-code": `{"type":"user","uuid":"u1","message":{"content":"Fix checkout"}}
{"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"Superseded proposal: delete the API"}]}}
{"type":"system","subtype":"compact_boundary","uuid":"b1"}
{"type":"user","uuid":"s1","isCompactSummary":true,"message":{"content":"Keep the public API. The migration rollback is still failing."}}
{"type":"user","uuid":"u2","parentUuid":"s1","message":{"content":"Correction: do not change billing periods"}}
{"type":"assistant","uuid":"a2","message":{"content":[{"type":"thinking","thinking":"private reasoning"},{"type":"tool_use","id":"cmd","name":"Bash","input":{"command":"go test ./billing"}}]}}
{"type":"user","uuid":"r1","message":{"content":[{"type":"tool_result","tool_use_id":"cmd","is_error":true,"content":"rollback failed"}]}}
`,
	}
	for source, body := range fixtures {
		t.Run(source, func(t *testing.T) {
			home := t.TempDir()
			var path string
			if source == "codex" {
				t.Setenv("CODEX_HOME", home)
				path = filepath.Join(home, "sessions", "rollout-test-fixture.jsonl")
			} else {
				t.Setenv("CLAUDE_CONFIG_DIR", home)
				path = filepath.Join(home, "projects", "-repo", "fixture.jsonl")
			}
			if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, []byte(body), 0600); err != nil {
				t.Fatal(err)
			}
			q := agent.HistoryQuery{SessionID: "fixture", ChatID: "source", CWD: "/repo", Recorded: []agent.Message{{Role: "user", Text: "Discarded recorded future"}}}
			exporter := nativeAdapter(t, source).(agent.HandoffHistoryProvider)
			history, err := exporter.ExportHandoff(context.Background(), q)
			if err != nil || !history.Available {
				t.Fatalf("export: %+v %v", history, err)
			}
			c := normalizeContext(agent.HandoffSource{AgentType: source, ChatID: "source", Revision: history.Revision, History: "native"}, history.Messages, history.Losses)
			if c.Summary == nil || c.Summary.Text != summary {
				t.Fatalf("missing summary %+v", c)
			}
			text := agent.RenderHandoffContext(c)
			if strings.Contains(text, "Superseded proposal") || strings.Contains(text, "Discarded recorded future") || strings.Contains(text, "private reasoning") || !strings.Contains(text, "Correction: do not change billing periods") || !strings.Contains(text, "failed") {
				t.Fatalf("unsafe context: %s", text)
			}
			failed := false
			for _, turn := range c.Turns {
				for _, tool := range turn.Tools {
					failed = failed || tool.Status == "failed"
				}
			}
			if !failed {
				t.Fatal("failed tool became prose or disappeared")
			}
			for _, target := range []string{"codex", "claude-code", "opencode", "grok"} {
				if target == source {
					continue
				}
				encoded, err := nativeAdapter(t, target).(agent.HandoffEncoder).EncodeHandoff(c, "Review checkout without changing the API")
				if err != nil {
					t.Fatal(err)
				}
				decoded, err := agent.DecodeHandoffPrompt(encoded.Message)
				if err != nil || decoded.TargetAgent != target || decoded.Context.Summary.Text != summary {
					t.Fatalf("%s -> %s: %+v %v", source, target, decoded, err)
				}
				a, _ := json.Marshal(c)
				b, _ := json.Marshal(decoded.Context)
				if string(a) != string(b) {
					t.Fatal("semantic round trip changed the capsule")
				}
			}
			// Undo/fork to the first native message must remain empty even with a full
			// recorded log available. The display-history merge must never resurrect it.
			q.Fork = &agent.ForkPoint{BeforeMessageID: history.Messages[0].ID, Fresh: true}
			empty, err := exporter.ExportHandoff(context.Background(), q)
			if err != nil || !empty.Available || len(empty.Messages) != 0 {
				t.Fatalf("empty native fork resurrected history: %+v %v", empty, err)
			}
			// A resumed source append changes the preview revision and survives export.
			q.Fork = nil
			appendBody := `{"type":"event_msg","payload":{"type":"user_message","message":"Resumed correction"}}` + "\n"
			if source == "claude-code" {
				appendBody = `{"type":"user","uuid":"resumed","message":{"content":"Resumed correction"}}` + "\n"
			}
			if err := os.WriteFile(path, []byte(body+appendBody), 0600); err != nil {
				t.Fatal(err)
			}
			resumed, err := exporter.ExportHandoff(context.Background(), q)
			if err != nil || resumed.Revision == history.Revision {
				t.Fatalf("resume revision: %v", err)
			}
			if !strings.Contains(agent.RenderHandoffContext(normalizeContext(c.Source, resumed.Messages, nil)), "Resumed correction") {
				t.Fatal("resumed instruction lost")
			}
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			missing, err := exporter.ExportHandoff(context.Background(), q)
			if err != nil || missing.Available {
				t.Fatalf("missing transcript became authoritative empty: %+v %v", missing, err)
			}
		})
	}
}

func TestCodexReplacementHistoryIsReadableWithoutPrivateState(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CODEX_HOME", home)
	path := filepath.Join(home, "sessions", "rollout-test-fixture.jsonl")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	body := `{"type":"compacted","payload":{"replacement_history":[{"type":"reasoning","encrypted_content":"private-ciphertext"},{"type":"message","role":"developer","content":"private-system"},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Keep the schema; verify rollback."}]}]}}` + "\n"
	if err := os.WriteFile(path, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	history, err := nativeAdapter(t, "codex").(agent.HandoffHistoryProvider).ExportHandoff(context.Background(), agent.HistoryQuery{SessionID: "fixture", ChatID: "source"})
	if err != nil {
		t.Fatal(err)
	}
	c := normalizeContext(agent.HandoffSource{AgentType: "codex", ChatID: "source", Revision: history.Revision, History: "native"}, history.Messages, nil)
	if c.Summary == nil || c.Summary.Text != "Keep the schema; verify rollback." || strings.Contains(agent.RenderHandoffContext(c), "private-") {
		t.Fatalf("replacement summary: %+v", c)
	}
}
