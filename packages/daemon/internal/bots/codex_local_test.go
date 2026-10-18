package bots

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
	"github.com/oblien/mindwire/packages/daemon/internal/runner"
	"github.com/oblien/mindwire/packages/daemon/internal/surface"
)

// Run the production desktop -> bots -> Codex pipeline against the installed
// CLI. Only the model is a local fixture; MCP discovery and calls are real.
// No account credentials, user configuration or paid model are used.
func TestCodexLocalComposedBotTools(t *testing.T) {
	if os.Getenv("CODEX_LOCAL") != "1" {
		t.Skip("set CODEX_LOCAL=1 to check the installed Codex CLI")
	}
	if _, err := exec.LookPath("codex"); err != nil {
		t.Fatal(err)
	}
	s, _ := testService(t)
	desktop, err := surface.New(s.db)
	if err != nil {
		t.Fatal(err)
	}
	defer desktop.Close()
	var requests atomic.Int32
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			Tools []map[string]any `json:"tools"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		index := requests.Add(1)
		var item map[string]any
		if index <= 2 {
			wanted := "bots_list"
			if index == 2 {
				wanted = "surface_status"
			}
			name := ""
			namespace := ""
			for _, tool := range request.Tools {
				if toolName, _ := tool["name"].(string); strings.HasSuffix(toolName, "__"+wanted) {
					name = toolName
				}
				if children, ok := tool["tools"].([]any); ok {
					for _, child := range children {
						if function, ok := child.(map[string]any); ok && function["name"] == wanted {
							name = wanted
							namespace, _ = tool["name"].(string)
						}
					}
				}
			}
			if name == "" {
				names := []any{}
				for _, tool := range request.Tools {
					names = append(names, tool["name"])
				}
				tools, _ := json.Marshal(names)
				t.Errorf("Codex did not discover %s in composed MCP tools: %s", wanted, tools)
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			item = map[string]any{"id": fmt.Sprintf("fc_%d", index), "type": "function_call", "status": "completed", "call_id": fmt.Sprintf("call_%d", index), "name": name, "arguments": "{}"}
			if namespace != "" {
				item["namespace"] = namespace
			}
		} else {
			item = map[string]any{"id": "msg_ready", "type": "message", "role": "assistant", "status": "completed", "phase": "final_answer", "content": []any{map[string]any{"type": "output_text", "text": "ready", "annotations": []any{}}}}
		}
		w.Header().Set("Content-Type", "text/event-stream")
		for _, event := range []map[string]any{
			{"type": "response.output_item.added", "output_index": 0, "item": item},
			{"type": "response.output_item.done", "output_index": 0, "item": item},
			{"type": "response.completed", "response": map[string]any{"id": fmt.Sprintf("resp_%d", index), "object": "response", "status": "completed", "output": []any{item}, "usage": map[string]any{"input_tokens": 10, "output_tokens": 5, "total_tokens": 15}}},
		} {
			data, _ := json.Marshal(event)
			_, _ = fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event["type"], data)
		}
	}))
	defer model.Close()
	codexDir := t.TempDir()
	t.Setenv("CODEX_HOME", codexDir)
	config := fmt.Sprintf("model = \"gpt-5-codex\"\nmodel_provider = \"local\"\n[model_providers.local]\nname = \"Local fixture\"\nbase_url = %q\nwire_api = \"responses\"\nrequires_openai_auth = false\n", model.URL)
	if err := os.WriteFile(filepath.Join(codexDir, "config.toml"), []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	var adapter agent.Adapter
	for _, a := range agent.All() {
		if a.ID() == "codex" {
			adapter = a
		}
	}
	ctx, cancel := context.WithTimeout(t.Context(), 45*time.Second)
	defer cancel()
	overlay, env, finishDesktop, err := desktop.BindRun(ctx, surface.Actor{Kind: "agent", RunID: "local-codex", ChatID: "chat"}, "codex", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer finishDesktop()
	turn, finishBot, err := s.Bind(ctx, adapter, runner.Turn{ChatID: "chat", Environment: env, Options: agent.TurnOptions{MCPServers: overlay}})
	if err != nil {
		t.Fatal(err)
	}
	defer finishBot()
	turn.Environment["CODEX_API_KEY"] = "local-test-key"
	turn.Environment["OPENAI_BASE_URL"] = model.URL
	seen := map[string]bool{}
	result, err := adapter.RunStream(ctx, agent.TurnInput{Message: "Check the bot and desktop tools.", CWD: t.TempDir(), Env: turn.Environment, Options: turn.Options, Inbound: make(chan agent.Inbound), Config: map[string]string{"model": "gpt-5-codex", "permission-mode": "never", "sandbox": "read-only"}}, func(ev agent.Event) {
		if ev.Type == agent.EventToolResult && ev.Tool != nil && !ev.Tool.IsError {
			seen[ev.Tool.Name] = true
		}
	})
	if err != nil || result.IsError || result.Text != "ready" {
		t.Fatalf("composed native turn: %+v %v", result, err)
	}
	for _, wanted := range []string{"bots_list", "surface_status"} {
		found := false
		for name := range seen {
			found = found || strings.HasSuffix(name, wanted)
		}
		if !found {
			t.Errorf("Codex did not finish %s", wanted)
		}
	}
}
