package opencode

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
)

func TestServerV2(t *testing.T) {
	const password = "per-turn-server-secret"
	prompted, approved, answered := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var mu sync.Mutex
	var created, prompt map[string]any
	var decision string
	var formAnswer map[string]any
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, pass, ok := r.BasicAuth()
		if !ok || user != "opencode" || pass != password {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		switch r.URL.Path {
		case "/global/health":
			w.Header().Set("Content-Type", "text/html")
			fmt.Fprint(w, "<html>OpenCode</html>") // V2's SPA fallback must not select V1.
		case "/api/info":
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"version":"2.0.29"}`)
		case "/api/session":
			var body map[string]any
			json.NewDecoder(r.Body).Decode(&body)
			mu.Lock()
			created = body
			mu.Unlock()
			fmt.Fprint(w, `{"data":{"id":"ses_v2"}}`)
		case "/api/session/ses_v2/prompt":
			var body map[string]any
			json.NewDecoder(r.Body).Decode(&body)
			mu.Lock()
			prompt = body
			mu.Unlock()
			close(prompted)
			fmt.Fprint(w, `{"data":{"id":"msg_input"}}`)
		case "/api/session/ses_v2/permission/perm_1/reply":
			var body struct {
				Decision string `json:"decision"`
			}
			json.NewDecoder(r.Body).Decode(&body)
			mu.Lock()
			decision = body.Decision
			mu.Unlock()
			close(approved)
			w.WriteHeader(http.StatusNoContent)
		case "/api/session/ses_v2/form/form_1/reply":
			var body struct {
				Answer map[string]any `json:"answer"`
			}
			json.NewDecoder(r.Body).Decode(&body)
			mu.Lock()
			formAnswer = body.Answer
			mu.Unlock()
			close(answered)
			w.WriteHeader(http.StatusNoContent)
		case "/api/event":
			w.Header().Set("Content-Type", "text/event-stream")
			send := func(kind string, data any) {
				raw, _ := json.Marshal(map[string]any{"type": kind, "data": data})
				fmt.Fprintf(w, "data: %s\n\n", raw)
				w.(http.Flusher).Flush()
			}
			await := func(ch <-chan struct{}) bool {
				select {
				case <-ch:
					return true
				case <-r.Context().Done():
					return false
				}
			}
			send("server.connected", map[string]any{})
			if !await(prompted) {
				return
			}
			send("session.execution.failed", map[string]any{"sessionID": "foreign", "error": map[string]string{"message": "ignore"}})
			send("permission.asked", map[string]any{"sessionID": "ses_v2", "id": "perm_1", "action": "read", "resources": []string{"main.go"}})
			if !await(approved) {
				return
			}
			send("form.created", map[string]any{"form": map[string]any{"id": "form_1", "sessionID": "ses_v2", "title": "Pick a scope", "fields": []any{map[string]any{"key": "scope", "type": "string", "required": true, "options": []any{map[string]string{"value": "small", "label": "Small"}}}}}})
			if !await(answered) {
				return
			}
			for _, e := range []struct {
				kind string
				data map[string]any
			}{
				{"session.text.delta", map[string]any{"delta": "Hello "}},
				{"session.text.delta", map[string]any{"delta": "世界"}},
				{"session.text.ended", map[string]any{"text": "Hello 世界"}},
				{"session.tool.input.started", map[string]any{"id": "call_1", "name": "read"}},
				{"session.tool.called", map[string]any{"id": "call_1", "input": map[string]string{"filePath": "main.go"}}},
				{"session.tool.success", map[string]any{"id": "call_1", "content": []any{map[string]string{"type": "text", "text": "package main"}}}},
				{"session.step.ended", map[string]any{"tokens": map[string]int{"input": 12, "output": 3}}},
				{"session.execution.succeeded", map[string]any{}},
			} {
				e.data["sessionID"], e.data["assistantMessageID"] = "ses_v2", "msg_1"
				send(e.kind, e.data)
			}
			<-r.Context().Done() // The adapter must close its long-lived subscription on return.
		default:
			t.Errorf("unexpected V2 request: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	srv := server{password: password, message: "Review only", cwd: "/project", provider: "example", model: "test#fast", interactive: true}
	v2, err := srv.waitHealthy(ctx, ts.URL)
	if err != nil || !v2 {
		t.Fatalf("protocol detection: v2=%v err=%v", v2, err)
	}
	srv.apiV2 = v2
	inbound := make(chan agent.Inbound, 4)
	col := &collector{}
	result, got := srv.converse(ctx, ts.URL, inbound, func(e agent.Event) {
		col.emit(e)
		if e.Interaction != nil {
			it := e.Interaction
			meta := map[string]string{}
			for k, v := range it.Meta {
				if value, ok := v.(string); ok {
					meta[k] = value
				}
			}
			if it.Kind == "approval" {
				inbound <- agent.Inbound{Kind: "response", InteractionID: it.ID, Decision: "allow"}
			} else {
				inbound <- agent.Inbound{Kind: "response", InteractionID: it.ID, Meta: meta, Answers: map[string]agent.QuestionAnswer{"scope": {Options: []string{"small"}}}}
			}
		}
	})
	if !got || result.IsError || result.Text != "Hello 世界" {
		t.Fatalf("V2 result: got=%v %+v", got, result)
	}
	mu.Lock()
	defer mu.Unlock()
	if created["location"].(map[string]any)["directory"] != "/project" || created["model"].(map[string]any)["variant"] != "fast" {
		t.Fatalf("session settings: %+v", created)
	}
	if prompt["text"] != "Review only" || decision != "once" || formAnswer["scope"] != "small" {
		t.Fatalf("prompt/approval/form mismatch: %v %q %v", prompt, decision, formAnswer)
	}
	var text strings.Builder
	uses, results := 0, 0
	for _, e := range col.snapshot() {
		if e.Type == agent.EventText {
			text.WriteString(e.Text)
		}
		if e.Type == agent.EventToolUse {
			uses++
		}
		if e.Type == agent.EventToolResult {
			results++
			if e.Tool.Output != "package main" {
				t.Errorf("tool output: %q", e.Tool.Output)
			}
		}
	}
	if text.String() != result.Text || uses != 1 || results != 1 {
		t.Fatalf("stream duplicate/loss: text=%q uses=%d results=%d", text.String(), uses, results)
	}
}

// Opt-in native protocol smoke: an isolated database and a local model stub mean
// this exercises the installed binary without provider charges or project edits.
func TestServerV2ProtocolLive(t *testing.T) {
	if os.Getenv("OPENCODE_PROTOCOL_LIVE") != "1" {
		t.Skip("set OPENCODE_PROTOCOL_LIVE=1 with OpenCode V2 installed")
	}
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/chat/completions") {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		for _, chunk := range []string{
			`{"id":"smoke","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"HANDOFF_READY"},"finish_reason":null}]}`,
			`{"id":"smoke","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}`,
			`[DONE]`,
		} {
			fmt.Fprintf(w, "data: %s\n\n", chunk)
			w.(http.Flusher).Flush()
		}
	}))
	defer model.Close()
	config, _ := json.Marshal(map[string]any{"providers": map[string]any{
		"mindwire-smoke": map[string]any{
			"package":  "@opencode/ai/providers/openai-compatible",
			"settings": map[string]any{"baseURL": model.URL + "/v1", "apiKey": "local-fixture"},
			"models":   map[string]any{"smoke": map[string]any{"name": "Local fixture"}},
		},
	}})
	workspace := t.TempDir()
	srv := server{cwd: workspace, provider: "mindwire-smoke", model: "smoke", message: "Reply HANDOFF_READY without tools.",
		env: map[string]string{"OPENCODE_DB": filepath.Join(workspace, "opencode.db"), "OPENCODE_CONFIG_CONTENT": string(config)}}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	col := &collector{}
	result, err := srv.Run(ctx, agent.TurnInput{}, col.emit)
	if err != nil || result.IsError || result.Text != "HANDOFF_READY" || firstOfType(col.snapshot(), agent.EventResult) == nil {
		t.Fatalf("native V2 protocol: result=%+v err=%v", result, err)
	}
	srv.resumeID = result.SessionID
	srv.contextInstructions = "This is a local protocol smoke test."
	resumed, err := srv.Run(ctx, agent.TurnInput{}, col.emit)
	if err != nil || resumed.IsError || resumed.Text != "HANDOFF_READY" || resumed.SessionID != result.SessionID {
		t.Fatalf("native V2 resume: result=%+v err=%v", resumed, err)
	}
	// A native provider failure must be a terminal error with its actual message.
	srv.resumeID, srv.contextInstructions = "", ""
	srv.provider = "mindwire-nonexistent-provider"
	failed, err := srv.Run(ctx, agent.TurnInput{}, col.emit)
	if err != nil || !failed.IsError || !strings.Contains(failed.Text, "Model unavailable") {
		t.Fatalf("native V2 failure: result=%+v err=%v", failed, err)
	}
}
