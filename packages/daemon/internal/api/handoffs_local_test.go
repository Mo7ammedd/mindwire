package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
	"github.com/oblien/mindwire/packages/daemon/internal/handoffs"
	"github.com/oblien/mindwire/packages/daemon/internal/registry"
)

// Actual native CLIs, isolated homes and local model protocols. Exercises native
// transcript -> HTTP preview -> target encoder -> supervised fresh CLI -> model.
// No personal histories, account credentials or paid API endpoints are used.
func TestHandoffNativeCLIsLocal(t *testing.T) {
	if os.Getenv("HANDOFF_NATIVE_LOCAL") != "1" {
		t.Skip("set HANDOFF_NATIVE_LOCAL=1; requires installed codex and claude binaries")
	}
	for _, binary := range []string{"codex", "claude"} {
		if _, err := exec.LookPath(binary); err != nil {
			t.Fatal(err)
		}
	}
	for _, source := range []string{"codex", "claude-code"} {
		t.Run(source, func(t *testing.T) {
			target := "codex"
			if source == "codex" {
				target = "claude-code"
			}
			h, store, a := newRegistryAPIEnv(t)
			h = registryAuthenticated(h)
			cwd, _ := filepath.EvalSymlinks(t.TempDir())
			for _, secret := range []string{"ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"} {
				t.Setenv(secret, "")
			}
			t.Setenv("AZURE_OPENAI_API_KEY", "local-provider-key")
			t.Setenv("ANTHROPIC_API_KEY", "local-claude-key")
			t.Setenv("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1")
			t.Setenv("DISABLE_AUTOUPDATER", "1")
			t.Setenv("CLAUDE_CODE_USE_BEDROCK", "0")
			t.Setenv("CLAUDE_CODE_USE_VERTEX", "0")
			t.Setenv("CLAUDE_CODE_USE_FOUNDRY", "0")
			var mu sync.Mutex
			var requests []string
			model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if strings.HasSuffix(r.URL.Path, "/count_tokens") {
					writeJSON(w, 200, map[string]int{"input_tokens": 10})
					return
				}
				if r.Method != "POST" {
					writeJSON(w, 200, map[string]any{"data": []any{}})
					return
				}
				body, _ := io.ReadAll(r.Body)
				mu.Lock()
				requests = append(requests, string(body))
				n := len(requests)
				mu.Unlock()
				text := "Keep the public API. The rollback test still needs review."
				if strings.Contains(string(body), "MINDWIRE_HANDOFF_V1") {
					text = "Handoff received with API constraint and remaining rollback review."
				}
				w.Header().Set("Content-Type", "text/event-stream")
				if strings.HasSuffix(r.URL.Path, "/responses") {
					item := map[string]any{"id": fmt.Sprintf("msg_%d", n), "type": "message", "role": "assistant", "phase": "final_answer", "status": "completed", "content": []any{map[string]any{"type": "output_text", "text": text, "annotations": []any{}}}}
					streamFixtureEvent(w, map[string]any{"type": "response.output_item.added", "output_index": 0, "item": item})
					streamFixtureEvent(w, map[string]any{"type": "response.output_text.delta", "output_index": 0, "content_index": 0, "item_id": item["id"], "delta": text})
					streamFixtureEvent(w, map[string]any{"type": "response.output_item.done", "output_index": 0, "item": item})
					streamFixtureEvent(w, map[string]any{"type": "response.completed", "response": map[string]any{"id": fmt.Sprintf("resp_%d", n), "object": "response", "status": "completed", "output": []any{item}, "usage": map[string]any{"input_tokens": 100, "output_tokens": 10, "total_tokens": 110}}})
					return
				}
				var req struct {
					Stream bool `json:"stream"`
				}
				_ = json.Unmarshal(body, &req)
				message := map[string]any{"id": fmt.Sprintf("msg_%d", n), "type": "message", "role": "assistant", "model": "claude-sonnet-4-6", "content": []any{}, "stop_reason": nil, "stop_sequence": nil, "usage": map[string]int{"input_tokens": 100, "output_tokens": 0}}
				if !req.Stream {
					message["content"] = []any{map[string]string{"type": "text", "text": text}}
					message["stop_reason"] = "end_turn"
					writeJSON(w, 200, message)
					return
				}
				streamFixtureEvent(w, map[string]any{"type": "message_start", "message": message})
				streamFixtureEvent(w, map[string]any{"type": "content_block_start", "index": 0, "content_block": map[string]string{"type": "text", "text": ""}})
				streamFixtureEvent(w, map[string]any{"type": "content_block_delta", "index": 0, "delta": map[string]string{"type": "text_delta", "text": text}})
				streamFixtureEvent(w, map[string]any{"type": "content_block_stop", "index": 0})
				streamFixtureEvent(w, map[string]any{"type": "message_delta", "delta": map[string]any{"stop_reason": "end_turn", "stop_sequence": nil}, "usage": map[string]int{"output_tokens": 10}})
				streamFixtureEvent(w, map[string]any{"type": "message_stop"})
			}))
			defer model.Close()
			t.Setenv("ANTHROPIC_BASE_URL", model.URL)
			config := fmt.Sprintf("model = \"gpt-5.5\"\nmodel_provider = \"azure-foundry\"\n[model_providers.azure-foundry]\nname = \"Local handoff fixture\"\nbase_url = %q\nenv_key = \"AZURE_OPENAI_API_KEY\"\nwire_api = \"responses\"\nrequires_openai_auth = false\nsupports_websockets = false\nrequest_max_retries = 0\nstream_max_retries = 0\n", model.URL)
			if err := os.WriteFile(filepath.Join(os.Getenv("CODEX_HOME"), "config.toml"), []byte(config), 0600); err != nil {
				t.Fatal(err)
			}
			codex, _ := a.sup.Resolve("codex")
			claude, _ := a.sup.Resolve("claude-code")
			for key, value := range map[string]string{"authMethod": "azureFoundry", "provider:azure-foundry:apiKey": "local-provider-key", "provider:azure-foundry:envVar": "AZURE_OPENAI_API_KEY", "provider:azure-foundry:models": "gpt-5.5", "permission-mode": "never", "sandbox": "danger-full-access"} {
				if err := codex.Creds.Set(key, value); err != nil {
					t.Fatal(err)
				}
			}
			_ = claude.Creds.Set("model", "claude-sonnet-4-6")
			_ = claude.Creds.Set("permission-mode", "bypassPermissions")
			src, _ := a.sup.Resolve(source)
			settings := map[string]string{"model": "gpt-5.5", "permission-mode": "never", "sandbox": "danger-full-access"}
			if source == "claude-code" {
				settings = map[string]string{"model": "claude-sonnet-4-6", "permission-mode": "bypassPermissions"}
			}
			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			defer cancel()
			native, err := src.Adapter.RunStream(ctx, agent.TurnInput{CWD: cwd, Message: "Review checkout. Keep the public API.", Config: settings}, func(agent.Event) {})
			if err != nil || native.IsError || native.SessionID == "" {
				t.Fatalf("source native turn: %+v %v", native, err)
			}
			if err := a.registry.Import(registry.Import{Agents: []registry.Agent{{Record: registry.Record{ID: "source-profile"}, AgentType: source, Name: "Source"}, {Record: registry.Record{ID: "target-profile"}, AgentType: target, Name: "Target"}}, Projects: []registry.Project{{Record: registry.Record{ID: "project"}, Name: "Fixture", Path: cwd}}, Chats: []registry.Chat{{Record: registry.Record{ID: "source"}, AgentID: "source-profile", ProjectID: "project", Title: "Checkout", SessionID: native.SessionID}}}); err != nil {
				t.Fatal(err)
			}
			response := serve(t, h, "GET", "/chats/source/handoff", "")
			var preview handoffs.Preview
			if response.Code != 200 || json.Unmarshal(response.Body.Bytes(), &preview) != nil || preview.HistorySource != "native" || !strings.Contains(preview.Context, "rollback test") {
				t.Fatalf("native preview: %d %s", response.Code, response.Body)
			}
			request := handoffs.Request{NewChatID: "destination", RequestID: "stable-local-receipt", TargetAgentID: "target-profile", Task: "Review the remaining rollback test", Context: &preview.Context, PreviewDigest: preview.Digest}
			payload, _ := json.Marshal(request)
			response = serve(t, h, "POST", "/chats/source/handoff", string(payload))
			var result handoffs.Result
			if response.Code != 202 || json.Unmarshal(response.Body.Bytes(), &result) != nil {
				t.Fatalf("handoff start: %d %s", response.Code, response.Body)
			}
			defer a.sup.Cancel(result.Run.ID)
			deadline := time.Now().Add(60 * time.Second)
			for a.sup.Busy(result.ChatID) && time.Now().Before(deadline) {
				time.Sleep(20 * time.Millisecond)
			}
			finished, _ := store.GetRun(result.Run.ID)
			if finished.Status != "done" {
				t.Fatalf("target native turn: %+v", finished)
			}
			if sid := store.Session(target, result.ChatID); sid == "" || sid == native.SessionID {
				t.Fatal("destination did not create a fresh native session")
			}
			mu.Lock()
			seen := append([]string(nil), requests...)
			mu.Unlock()
			reached := false
			for _, body := range seen {
				var value any
				_ = json.Unmarshal([]byte(body), &value)
				var inspect func(any)
				inspect = func(v any) {
					switch node := v.(type) {
					case string:
						if strings.Contains(node, "MINDWIRE_HANDOFF_V1") {
							decoded, err := agent.DecodeHandoffPrompt(node)
							if err == nil && decoded.TargetAgent == target && strings.Contains(agent.RenderHandoffContext(decoded.Context), "rollback test") {
								reached = true
							}
						}
					case []any:
						for _, child := range node {
							inspect(child)
						}
					case map[string]any:
						for _, child := range node {
							inspect(child)
						}
					}
				}
				inspect(value)
			}
			if !reached {
				t.Fatalf("portable payload never reached %s model transport (%d calls)", target, len(seen))
			}
			response = serve(t, h, "POST", "/chats/source/handoff", string(payload))
			var retry handoffs.Result
			if response.Code != 202 || json.Unmarshal(response.Body.Bytes(), &retry) != nil || retry.Run.ID != result.Run.ID {
				t.Fatalf("retry duplicated the run: %d %s", response.Code, response.Body)
			}
			mu.Lock()
			after := len(requests)
			mu.Unlock()
			if after != len(seen) {
				t.Fatal("retry called a model again")
			}
		})
	}
}
