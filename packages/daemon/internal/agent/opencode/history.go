package opencode

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/url"
	"path/filepath"
	"strings"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
	"github.com/oblien/mindwire/packages/daemon/internal/workspacepath"
)

var _ agent.HistoryRevisionProvider = adapter{}

// Include the live WAL: statting only opencode.db would miss changes made by
// an OpenCode process that has not checkpointed its recent messages yet.
func (adapter) HistoryRevision(q agent.HistoryQuery) (string, error) {
	path := nativeDBPath()
	if q.SessionID == "" || path == "" {
		return "missing", nil
	}
	main, err := agent.NativeHistoryFileRevision(path)
	if err != nil {
		return "", err
	}
	wal, err := agent.NativeHistoryFileRevision(path + "-wal")
	if err != nil {
		return "", err
	}
	return main + ":" + wal, nil
}

// History reads a consistent native snapshot. The daemon's recorded stream stays
// the API fallback if the store is missing, busy, or from an incompatible version.
// No HistoryDeleter is implemented: importing does not grant ownership of the DB.
func (adapter) History(q agent.HistoryQuery) ([]agent.Message, error) {
	if q.SessionID == "" {
		return nil, nil
	}
	if !agent.ValidNativeSessionID(q.SessionID) {
		return nil, fmt.Errorf("invalid OpenCode session ID")
	}
	db, err := nativeDB()
	if err != nil || db == nil {
		return nil, err
	}
	defer db.Close()
	ctx, cancel := nativeReadContext()
	defer cancel()
	tx, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var directory string
	var revert sql.NullString
	err = tx.QueryRowContext(ctx, `SELECT directory, revert FROM session WHERE id = ?`, q.SessionID).Scan(&directory, &revert)
	if err == sql.ErrNoRows {
		if len(q.Recorded) > 0 {
			// V2 sessions are not projected into the legacy session/part tables.
			// Preserve the recorded transcript rather than treating a missing row
			// as a successful, authoritatively empty native conversation.
			return nil, fmt.Errorf("OpenCode session is absent from the legacy history store")
		}
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if q.CWD != "" {
		actual, err := workspacepath.Canonical(directory)
		if err != nil {
			return nil, err
		}
		requested, err := workspacepath.Canonical(q.CWD)
		if err != nil || actual != requested {
			return nil, fmt.Errorf("OpenCode conversation belongs to another directory")
		}
	}
	var reverted struct {
		MessageID string `json:"messageID"`
	}
	if revert.Valid && revert.String != "" {
		if err := json.Unmarshal([]byte(revert.String), &reverted); err != nil {
			return nil, fmt.Errorf("invalid OpenCode revert metadata: %w", err)
		}
	}
	rows, err := tx.QueryContext(ctx, `SELECT m.id, m.time_created, m.data, p.id, p.data
		FROM message m LEFT JOIN part p ON p.message_id = m.id AND p.session_id = m.session_id
		WHERE m.session_id = ? ORDER BY m.time_created, m.id, p.id`, q.SessionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []agent.Message
	var current *storedMessage
	flush := func() {
		if current != nil {
			out = appendNativeMessage(out, *current, q.ChatID)
		}
	}
	for rows.Next() {
		var id, data string
		var created int64
		var partID, partData sql.NullString
		if err := rows.Scan(&id, &created, &data, &partID, &partData); err != nil {
			return nil, err
		}
		if current == nil || current.ID != id {
			flush()
			current = nil
			if reverted.MessageID != "" && id >= reverted.MessageID {
				break // OpenCode keeps reverted messages on disk for redo
			}
			current = &storedMessage{ID: id, Created: created}
			if err := json.Unmarshal([]byte(data), &current.Info); err != nil {
				return nil, fmt.Errorf("invalid OpenCode message: %w", err)
			}
		}
		if partID.Valid && partData.Valid {
			var part storedPart
			if err := json.Unmarshal([]byte(partData.String), &part); err != nil {
				return nil, fmt.Errorf("invalid OpenCode message part: %w", err)
			}
			part.ID = partID.String
			current.Parts = append(current.Parts, part)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	flush()
	if reverted.MessageID == "" {
		// Keep Mindwire-only failures, notices and attachment receipts when switching
		// existing chats from recorded to native history. A native undo is authoritative.
		out = agent.MergeRecordedHistory(out, q.Recorded)
	}
	return out, nil
}

type storedMessage struct {
	ID      string
	Created int64
	Info    struct {
		Role    string          `json:"role"`
		Summary json.RawMessage `json:"summary"` // bool for assistants, title/body object for users
	}
	Parts []storedPart
}

type storedPart struct {
	ocPart
	Ignored  bool   `json:"ignored"`
	Auto     bool   `json:"auto"`
	Mime     string `json:"mime"`
	URL      string `json:"url"`
	Filename string `json:"filename"`
}

func appendNativeMessage(out []agent.Message, row storedMessage, chatID string) []agent.Message {
	if row.Info.Role != "user" && row.Info.Role != "assistant" {
		return out
	}
	m := agent.Message{ID: row.ID, ChatID: chatID, Role: row.Info.Role, CreatedAt: nativeTime(row.Created)}
	var text []string
	for _, p := range row.Parts {
		if p.Synthetic || p.Ignored {
			continue
		}
		part := agent.Part{ID: p.ID, At: m.CreatedAt}
		switch p.Type {
		case "text", "reasoning":
			if strings.TrimSpace(p.Text) == "" {
				continue
			}
			part.Type, part.Text = "text", p.Text
			if p.Type == "reasoning" {
				part.Type = "thinking"
			} else {
				text = append(text, p.Text)
			}
		case "tool":
			if p.Tool == "todowrite" {
				newStreamState().emitTodos(p.ocPart, func(e agent.Event) {
					m.Parts = append(m.Parts, agent.Part{Type: "interaction", ID: p.ID, At: m.CreatedAt, Interaction: e.Interaction})
				})
				continue
			}
			output, isError := toolResult(p.State)
			var input json.RawMessage
			if p.State != nil {
				input = p.State.Input
			}
			part.Type = "tool"
			part.Tool = &agent.ToolPart{ID: agent.FirstNonEmpty(p.CallID, p.ID), Name: p.Tool,
				Input: input, Output: output, IsError: isError, Action: ocToolAction(p.Tool, input)}
			if p.State != nil {
				part.Tool.Status = p.State.Status
			}
		case "compaction":
			trigger := "manual"
			if p.Auto {
				trigger = "auto"
			}
			part.Type, part.Compaction = "compaction", &agent.CompactionInfo{Trigger: trigger}
			m.Role = "system"
		case "file":
			if attachment, ok := nativeAttachment(p); ok {
				m.Attachments = append(m.Attachments, attachment)
			}
			continue
		default:
			continue
		}
		m.Parts = append(m.Parts, part)
	}
	m.Text = strings.Join(text, "\n")
	if row.Info.Role == "assistant" && string(row.Info.Summary) == "true" {
		// The summarizer's output is context attached to the preceding boundary.
		for i := len(out) - 1; i >= 0; i-- {
			for j := range out[i].Parts {
				if c := out[i].Parts[j].Compaction; c != nil {
					c.Summary = m.Text
					return out
				}
			}
		}
		m.Role, m.Text = "system", ""
		m.Parts = []agent.Part{{Type: "compaction", At: m.CreatedAt, Compaction: &agent.CompactionInfo{Summary: strings.Join(text, "\n")}}}
	}
	if len(m.Parts) > 0 || len(m.Attachments) > 0 {
		out = append(out, m)
	}
	return out
}

func nativeAttachment(p storedPart) (agent.Attachment, bool) {
	if at, ok := agent.ImageFromDataURL(p.URL); ok {
		at.Name = p.Filename
		return at, true
	}
	u, err := url.Parse(p.URL)
	if err != nil || u.Scheme != "file" || u.Host != "" && u.Host != "localhost" {
		return agent.Attachment{}, false
	}
	path := filepath.FromSlash(u.Path)
	if !filepath.IsAbs(path) {
		return agent.Attachment{}, false
	}
	return agent.Attachment{Name: p.Filename, Mime: p.Mime, Path: path}, true
}
