package grok

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
)

var _ agent.HistoryRevisionProvider = adapter{}

func (adapter) HistoryRevision(q agent.HistoryQuery) (string, error) {
	s, err := nativeSummaryFor(q)
	if err != nil || s == nil {
		return "missing", err
	}
	metadata, err := agent.NativeHistoryFileRevision(s.path)
	if err != nil {
		return "", err
	}
	updates, err := agent.NativeHistoryFileRevision(filepath.Join(filepath.Dir(s.path), "updates.jsonl"))
	return metadata + ":" + updates, err
}

type nativeUpdate struct {
	SessionID string `json:"sessionId"`
	Update    struct {
		Type              string          `json:"sessionUpdate"`
		Content           json.RawMessage `json:"content"`
		ToolCallID        string          `json:"toolCallId"`
		Title             string          `json:"title"`
		Status            string          `json:"status"`
		RawInput          json.RawMessage `json:"rawInput"`
		RawOutput         json.RawMessage `json:"rawOutput"`
		TargetPromptIndex *int            `json:"target_prompt_index"`
		Meta              struct {
			PromptIndex *int `json:"promptIndex"`
			HostTurn    bool `json:"hostTurn"`
		} `json:"_meta"`
		Entries []agent.TodoItem `json:"entries"`
	} `json:"update"`
	method string
	at     string
	line   int
}

// updates.jsonl is Grok's visible ACP transcript. Read only complete JSONL
// records, including the legacy unwrapped notification format. A torn final
// append is retried on the next read; malformed committed records fail history.
func (adapter) History(q agent.HistoryQuery) ([]agent.Message, error) {
	s, err := nativeSummaryFor(q)
	if err != nil || s == nil {
		return nil, err
	}
	f, err := os.Open(filepath.Join(filepath.Dir(s.path), "updates.jsonl"))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	reader := bufio.NewReader(f)
	var updates []nativeUpdate
	var promptStarts []int
	inUser, seenIndex := false, false
	var previousIndex *int
	rewound := false
	for line := 1; ; line++ {
		// Bound individual records without accepting an incomplete EOF as a
		// committed line. Tool records share the other readers' 16 MiB cap.
		data, err := readNativeLine(reader)
		if err != nil {
			return nil, err
		}
		if data == nil {
			break
		}
		if strings.TrimSpace(string(data)) == "" {
			continue
		}
		var envelope struct {
			Timestamp int64           `json:"timestamp"`
			Method    string          `json:"method"`
			Params    json.RawMessage `json:"params"`
		}
		if err := json.Unmarshal(data, &envelope); err != nil {
			return nil, fmt.Errorf("invalid Grok transcript record: %w", err)
		}
		payload := envelope.Params
		if envelope.Method == "" {
			payload = data
		}
		var event nativeUpdate
		if err := json.Unmarshal(payload, &event); err != nil {
			return nil, fmt.Errorf("invalid Grok session update: %w", err)
		}
		if event.SessionID != "" && event.SessionID != q.SessionID {
			continue
		}
		event.method, event.line = envelope.Method, line
		event.at = s.Created.UTC().Format(time.RFC3339Nano)
		if envelope.Timestamp > 0 {
			event.at = time.Unix(envelope.Timestamp, 0).UTC().Format(time.RFC3339Nano)
		}
		u := event.Update
		if event.method == "_x.ai/session/update" && u.Type == "rewind_marker" && u.TargetPromptIndex != nil && *u.TargetPromptIndex >= 0 {
			target := *u.TargetPromptIndex
			if target < len(promptStarts) {
				updates = updates[:promptStarts[target]]
			}
			promptStarts = promptStarts[:min(target, len(promptStarts))]
			inUser, previousIndex, rewound = false, nil, true
			continue
		}
		if event.method != "_x.ai/session/update" && u.Type == "user_message_chunk" && !u.Meta.HostTurn {
			index := u.Meta.PromptIndex
			seenIndex = seenIndex || index != nil
			changed := (index == nil) != (previousIndex == nil) || index != nil && previousIndex != nil && *index != *previousIndex
			if (!inUser || changed) && (!seenIndex || index != nil) {
				promptStarts = append(promptStarts, len(updates))
			}
			inUser, previousIndex = true, index
		} else {
			inUser, previousIndex = false, nil
		}
		updates = append(updates, event)
	}
	out := nativeMessages(updates, q.ChatID)
	if !rewound {
		out = agent.MergeRecordedHistory(out, q.Recorded)
	}
	return out, nil
}

func readNativeLine(r *bufio.Reader) ([]byte, error) {
	var line []byte
	for {
		fragment, err := r.ReadSlice('\n')
		line = append(line, fragment...)
		if len(line) > 16<<20 {
			return nil, fmt.Errorf("Grok transcript record exceeds 16 MiB")
		}
		if err == bufio.ErrBufferFull {
			continue
		}
		if err == io.EOF {
			return nil, nil // an unfinished append is not part of the committed transcript
		}
		return line, err
	}
}

func nativeMessages(updates []nativeUpdate, chatID string) []agent.Message {
	var out []agent.Message
	type toolLocation struct{ message, part int }
	tools := map[string]toolLocation{}
	var lastPrompt *int
	message := func(role string, event nativeUpdate, force bool) *agent.Message {
		if force || len(out) == 0 || out[len(out)-1].Role != role {
			out = append(out, agent.Message{ID: fmt.Sprintf("grok-%d", event.line), ChatID: chatID, Role: role, CreatedAt: event.at})
		}
		return &out[len(out)-1]
	}
	for _, event := range updates {
		u := event.Update
		if event.method == "_x.ai/session/update" {
			if u.Type == "compaction_checkpoint" {
				m := message("system", event, true)
				m.Parts = []agent.Part{{Type: "compaction", At: event.at, Compaction: &agent.CompactionInfo{}}}
			}
			continue
		}
		switch u.Type {
		case "user_message_chunk", "agent_message_chunk", "agent_thought_chunk":
			if u.Meta.HostTurn {
				continue
			}
			text := nativeContentText(u.Content)
			var content struct {
				Type string `json:"type"`
				Data string `json:"data"`
				Mime string `json:"mimeType"`
			}
			_ = json.Unmarshal(u.Content, &content)
			image, hasImage := agent.ImageFromDataURL("data:" + content.Mime + ";base64," + content.Data)
			if text == "" && !hasImage {
				continue
			}
			role, kind := "assistant", "text"
			if u.Type == "user_message_chunk" {
				role = "user"
			}
			if u.Type == "agent_thought_chunk" {
				kind = "thinking"
			}
			index := u.Meta.PromptIndex
			newPrompt := role == "user" && index != nil && lastPrompt != nil && *index != *lastPrompt
			m := message(role, event, newPrompt)
			if role == "user" {
				lastPrompt = index
			}
			if hasImage {
				m.Attachments = append(m.Attachments, image)
			}
			if text != "" {
				if n := len(m.Parts); n > 0 && m.Parts[n-1].Type == kind {
					m.Parts[n-1].Text += text
				} else {
					m.Parts = append(m.Parts, agent.Part{Type: kind, Text: text, At: event.at})
				}
				if kind == "text" {
					m.Text += text
				}
			}
		case "tool_call", "tool_call_update":
			if u.ToolCallID == "" {
				continue
			}
			location, found := tools[u.ToolCallID]
			if !found {
				m := message("assistant", event, false)
				location = toolLocation{len(out) - 1, len(m.Parts)}
				m.Parts = append(m.Parts, agent.Part{Type: "tool", At: event.at, Tool: &agent.ToolPart{ID: u.ToolCallID}})
				tools[u.ToolCallID] = location
			}
			tool := out[location.message].Parts[location.part].Tool
			if u.Title != "" {
				tool.Name = u.Title
			}
			if len(u.RawInput) > 0 {
				tool.Input = u.RawInput
			}
			if len(u.Content) > 0 {
				tool.Output = nativeContentText(u.Content)
			} else if len(u.RawOutput) > 0 {
				tool.Output = nativeContentText(u.RawOutput)
				if tool.Output == "" {
					tool.Output = string(u.RawOutput)
				}
			}
			if u.Status != "" {
				tool.IsError = u.Status == "failed"
			}
		case "plan":
			if len(u.Entries) > 0 {
				m := message("assistant", event, false)
				m.Parts = append(m.Parts, agent.Part{Type: "interaction", At: event.at,
					Interaction: &agent.Interaction{Kind: "todos", Items: u.Entries}})
			}
		}
	}
	return out
}

// ACP message content is an object; tool results are arrays of content wrappers.
func nativeContentText(raw json.RawMessage) string {
	var value any
	if json.Unmarshal(raw, &value) != nil {
		return ""
	}
	var text func(any) string
	text = func(value any) string {
		switch v := value.(type) {
		case string:
			return v
		case map[string]any:
			if s, ok := v["text"].(string); ok {
				return s
			}
			return text(v["content"])
		case []any:
			var chunks []string
			for _, item := range v {
				if s := text(item); s != "" {
					chunks = append(chunks, s)
				}
			}
			return strings.Join(chunks, "\n")
		}
		return ""
	}
	return text(value)
}
