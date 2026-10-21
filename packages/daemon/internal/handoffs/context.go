package handoffs

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
)

func addLoss(c *agent.HandoffContext, code string, count int) {
	if count < 1 {
		return
	}
	for i := range c.Losses {
		if c.Losses[i].Code == code {
			c.Losses[i].Count += count
			return
		}
	}
	c.Losses = append(c.Losses, agent.HandoffLoss{Code: code, Count: count})
}

// boundedText keeps both the beginning and end: final corrections often occur
// at the end of a long turn. Every cut is reported, including UTF-8 replacement.
func boundedText(c *agent.HandoffContext, text string, limit int, loss string) string {
	if !utf8.ValidString(text) {
		text = strings.ToValidUTF8(text, "�")
		addLoss(c, "invalid_utf8_replaced", 1)
	}
	if len(text) <= limit {
		return text
	}
	addLoss(c, loss, 1)
	marker := "\n[truncated]\n"
	if limit <= len(marker) {
		for limit > 0 && !utf8.RuneStart(text[limit]) {
			limit--
		}
		return text[:limit]
	}
	room := limit - len(marker)
	head := room / 2
	for head > 0 && !utf8.RuneStart(text[head]) {
		head--
	}
	tail := len(text) - (room - head)
	for tail < len(text) && !utf8.RuneStart(text[tail]) {
		tail++
	}
	return text[:head] + marker + text[tail:]
}

func visibleText(m agent.Message) string {
	if m.Text != "" {
		return m.Text
	}
	var pieces []string
	for _, p := range m.Parts {
		if p.Type == "text" && p.Text != "" {
			pieces = append(pieces, p.Text)
		}
	}
	return strings.Join(pieces, "\n")
}

// The display Text field joins assistant prose across tools and steering. Split
// ordered parts before packing so accepted user corrections keep their role and
// position, and a tool outcome cannot move after the answer that relied on it.
func orderedHistory(c *agent.HandoffContext, messages []agent.Message) []agent.Message {
	var out []agent.Message
	for _, m := range messages {
		if m.Role != "assistant" || len(m.Parts) == 0 {
			out = append(out, m)
			continue
		}
		hadText := false
		for i, p := range m.Parts {
			row := agent.Message{ID: fmt.Sprintf("%s/part-%d", m.ID, i), Role: "assistant"}
			switch {
			case p.Input != nil:
				if p.Input.Status != "accepted" {
					addLoss(c, "undelivered_input", 1)
					continue
				}
				row.Role, row.Text, row.Attachments = "user", p.Input.Text, p.Input.Attachments
			case p.Type == "text":
				hadText = true
				row.Text = p.Text
			case p.Type == "tool", p.Type == "interaction":
				row.Parts = []agent.Part{p}
			case p.Type == "compaction":
				row.Role, row.Parts = "system", []agent.Part{p}
			case p.Type == "thinking":
				continue
			default:
				addLoss(c, "unsupported_part", 1)
				continue
			}
			out = append(out, row)
		}
		if !hadText && m.Text != "" {
			out = append(out, agent.Message{ID: m.ID, Role: m.Role, Text: m.Text})
		}
		if len(m.Attachments) > 0 {
			out = append(out, agent.Message{ID: m.ID + "/artifacts", Role: m.Role, Attachments: m.Attachments})
		}
	}
	return out
}

func normalizedTool(c *agent.HandoffContext, p *agent.ToolPart) agent.HandoffTool {
	result := agent.HandoffTool{Kind: agent.KindOther, Status: "unknown"}
	if p.IsError {
		result.Status = "failed"
	} else if p.Status == "completed" || p.Status == "failed" {
		result.Status = p.Status
	}
	if p.Action == nil {
		if p.Output != "" {
			addLoss(c, "tool_output_omitted", 1)
		}
		addLoss(c, "unmapped_tool", 1)
		return result
	}
	a := p.Action
	switch a.Kind {
	case agent.KindFileEdit, agent.KindFileRead, agent.KindShell, agent.KindSearch, agent.KindWebSearch, agent.KindWebFetch, agent.KindMCP, agent.KindOther:
		result.Kind = a.Kind
	default:
		addLoss(c, "unmapped_tool", 1)
	}
	result.Title = boundedText(c, a.Title, 256, "tool_details_truncated")
	for i, file := range a.Files {
		if i >= 16 {
			addLoss(c, "file_references_omitted", len(a.Files)-i)
			break
		}
		if len(file.Path) > 1024 || !utf8.ValidString(file.Path) {
			addLoss(c, "file_references_omitted", 1)
			continue
		}
		result.Files = append(result.Files, agent.FileChange{Path: file.Path, Op: file.Op})
	}
	if a.Shell != nil {
		result.Command = boundedText(c, a.Shell.Command, 1024, "tool_details_truncated")
		result.ExitCode = a.Shell.ExitCode
		if a.Shell.ExitCode != nil {
			if *a.Shell.ExitCode != 0 {
				result.Status = "failed"
			} else if !p.IsError {
				result.Status = "completed"
			}
		}
		result.Output = boundedText(c, a.Shell.Stdout, 1024, "tool_result_truncated")
	} else if p.Output != "" {
		// Unknown/MCP payloads and raw edit bodies can contain private inputs. Keep
		// normalized outcome, file effects and status; disclose excluded body text.
		addLoss(c, "tool_output_omitted", 1)
	}
	return result
}

func normalizeTurn(c *agent.HandoffContext, m agent.Message) agent.HandoffTurn {
	turn := agent.HandoffTurn{ID: m.ID, Role: m.Role, Text: boundedText(c, visibleText(m), 4096, "text_truncated")}
	for _, part := range m.Parts {
		if part.Type != "tool" || part.Tool == nil {
			continue
		}
		if len(turn.Tools) >= 16 {
			addLoss(c, "tools_omitted", 1)
			continue
		}
		turn.Tools = append(turn.Tools, normalizedTool(c, part.Tool))
	}
	for i, a := range m.Attachments {
		if i >= 16 {
			addLoss(c, "artifacts_omitted", len(m.Attachments)-i)
			break
		}
		if len(a.Path) > 4096 {
			addLoss(c, "artifacts_omitted", 1)
			continue
		}
		ref := agent.HandoffArtifact{Name: boundedText(c, a.Name, 256, "artifact_metadata_truncated"), Path: a.Path, ArtifactID: a.ArtifactID, Mime: a.Mime, Bytes: a.Bytes, Available: a.Path != ""}
		if !ref.Available {
			addLoss(c, "artifact_content_unavailable", 1)
		}
		turn.Artifacts = append(turn.Artifacts, ref)
	}
	return turn
}

// normalizeContext retains the latest continuation summary and only the turns
// it does not supersede. If a compaction is opaque, retain available evidence
// instead of claiming an empty/missing summary is a complete reconstruction.
func normalizeContext(source agent.HandoffSource, messages []agent.Message, losses []agent.HandoffLoss) agent.HandoffContext {
	c := agent.HandoffContext{Version: agent.HandoffContextVersion, Source: source}
	messages = orderedHistory(&c, messages)
	for _, loss := range losses {
		addLoss(&c, loss.Code, loss.Count)
	}
	boundary := -1
	for i, m := range messages {
		if c.Goal == "" && m.Role == "user" {
			c.Goal = boundedText(&c, visibleText(m), 4096, "goal_truncated")
		}
		for _, p := range m.Parts {
			if p.Type != "compaction" || p.Compaction == nil {
				continue
			}
			if strings.TrimSpace(p.Compaction.Summary) == "" {
				addLoss(&c, "compaction_summary_unavailable", 1)
				continue
			}
			boundary = i
			c.Summary = &agent.HandoffSummary{MessageID: m.ID, Text: boundedText(&c, p.Compaction.Summary, 12<<10, "summary_truncated")}
		}
	}
	// The latest task snapshot replaces previous snapshots; task list history is
	// not a sequence of instructions to perform again.
	for _, m := range messages[max(0, boundary+1):] {
		for _, p := range m.Parts {
			if p.Interaction != nil && p.Interaction.Kind == "todos" {
				c.Tasks = append([]agent.TodoItem(nil), p.Interaction.Items...)
			}
		}
	}
	used := 0
	for i, task := range c.Tasks {
		task.Content = boundedText(&c, task.Content, 512, "tasks_truncated")
		if used+len(task.Content) > 4096 || i >= 64 {
			addLoss(&c, "tasks_omitted", len(c.Tasks)-i)
			c.Tasks = c.Tasks[:i]
			break
		}
		used += len(task.Content)
		c.Tasks[i] = task
	}
	// Reserve loss-report space, then admit complete newest turns under BOTH wire
	// and review byte limits. There is no arbitrary last-twelve-message cutoff.
	base, _ := json.Marshal(c)
	wireRemaining := MaxContextBytes - len(base) - 2048
	textRemaining := MaxContextBytes - len(agent.RenderHandoffContext(c)) - 2048
	var recent []agent.HandoffTurn
	for i := len(messages) - 1; i > boundary; i-- {
		m := messages[i]
		if m.Role != "user" && m.Role != "assistant" {
			continue
		}
		turn := normalizeTurn(&c, m)
		if turn.Text == "" && len(turn.Tools) == 0 && len(turn.Artifacts) == 0 {
			continue
		}
		encoded, _ := json.Marshal(turn)
		rendered := agent.RenderHandoffContext(agent.HandoffContext{Turns: []agent.HandoffTurn{turn}})
		if len(encoded)+1 > wireRemaining || len(rendered) > textRemaining {
			addLoss(&c, "messages_omitted", 1)
			continue
		}
		recent = append(recent, turn)
		wireRemaining -= len(encoded) + 1
		textRemaining -= len(rendered)
	}
	for i := len(recent) - 1; i >= 0; i-- {
		c.Turns = append(c.Turns, recent[i])
	}
	return c
}

// Editing the review removes all original fields, including tool results or
// artifact references the user may have deliberately deleted.
func reviewedContext(source agent.HandoffSource, text string, losses []agent.HandoffLoss) agent.HandoffContext {
	return agent.HandoffContext{Version: agent.HandoffContextVersion, Source: source, Reviewed: true,
		Turns: []agent.HandoffTurn{{Role: "user", Text: text}}, Losses: append([]agent.HandoffLoss(nil), losses...)}
}

// Kept as a small compatibility helper for the existing text-review tests.
func contextText(messages []agent.Message) (string, bool) {
	c := normalizeContext(agent.HandoffSource{AgentType: "recorded", ChatID: "context", Revision: "context", History: "recorded"}, messages, nil)
	return agent.RenderHandoffContext(c), len(c.Losses) > 0
}
