package registry

import (
	"database/sql"
	"encoding/json"
	"errors"
)

const HandoffVersion = 2

// HandoffOrigin is immutable provenance, not a native session to resume.
type HandoffOrigin struct {
	ChatID  string `json:"chatId"`
	AgentID string `json:"agentId"`
	Title   string `json:"title"`
	RunID   string `json:"runId,omitempty"`
}

// HandoffReceipt retains the reviewed prompt so retries cannot capture newer
// source context or execute a different task under the same receipt.
type HandoffReceipt struct {
	ChatID         string `json:"chatId"`
	SourceChatID   string `json:"sourceChatId"`
	TargetAgentID  string `json:"targetAgentId"`
	RequestID      string `json:"requestId"`
	Digest         string `json:"digest"`
	Message        string `json:"message"`
	ContextVersion int    `json:"contextVersion,omitempty"`
	ContextDigest  string `json:"contextDigest,omitempty"`
	Codec          string `json:"codec,omitempty"`
}

func (st *Store) Handoff(chatID string) (HandoffReceipt, error) {
	var receipt HandoffReceipt
	err := st.SurfaceGet("chat-handoff", chatID, &receipt)
	return receipt, err
}

// CreateHandoff saves the new chat and its receipt in one registry transaction.
// The caller serializes this with ordinary chat mutations and run admission.
func (st *Store) CreateHandoff(chat Chat, receipt HandoffReceipt) error {
	return st.write(func(tx *sql.Tx, revision int64) (bool, error) {
		if !validID(chat.ID) || chat.ID != receipt.ChatID || chat.ID == receipt.SourceChatID {
			return false, invalid("handoff requires a new, different chat ID")
		}
		gone, err := isDeleted(tx, "chats", chat.ID)
		if err != nil {
			return false, err
		}
		if gone {
			return false, ErrDeleted
		}
		previous, _, err := record(tx, "chats", chat.ID)
		if err != nil {
			return false, err
		}
		if previous != nil {
			return false, ErrConflict
		}
		source, _, err := record(tx, "chats", receipt.SourceChatID)
		if err != nil {
			return false, err
		}
		if source == nil {
			return false, ErrNotFound
		}
		var original Chat
		if err = json.Unmarshal(source, &original); err != nil {
			return false, err
		}
		if original.ProjectID != chat.ProjectID || receipt.TargetAgentID != chat.AgentID || chat.HandoffFrom == nil {
			return false, invalid("handoffs must remain in the source project")
		}
		data, _ := json.Marshal(chat)
		data, agentID, projectID, err := st.normalize("chats", chat.ID, data, revision)
		if err != nil {
			return false, err
		}
		var normalized Chat
		_ = json.Unmarshal(data, &normalized)
		normalized.HandoffFrom = chat.HandoffFrom
		data, _ = json.Marshal(normalized)
		if err = save(tx, "chats", chat.ID, data, revision, agentID, projectID); err != nil {
			return false, err
		}
		payload, err := json.Marshal(receipt)
		if err != nil {
			return false, err
		}
		_, err = tx.Exec("INSERT INTO surface_records(kind,id,data,updated_at) VALUES('chat-handoff',?,?,?)", chat.ID, payload, operationNow())
		return true, err
	})
}

func (st *Store) HandoffTarget(chatID string) (*Chat, *Agent, *Project, error) {
	chat, profile, project, err := st.ChatContext(chatID)
	if err == nil && chat == nil {
		err = ErrNotFound
	}
	return chat, profile, project, err
}

// Handoff receipts contain conversation text. Delete them together with their
// destination chat, including cascaded deletion of a project or agent profile.
func deleteHandoffReceipts(tx *sql.Tx, kind, id string) error {
	query := "DELETE FROM surface_records WHERE kind='chat-handoff' AND id=?"
	if kind == "agents" || kind == "projects" {
		column := "agent_id"
		if kind == "projects" {
			column = "project_id"
		}
		query = "DELETE FROM surface_records WHERE kind='chat-handoff' AND id IN (SELECT id FROM chats WHERE " + column + "=?)"
	} else if kind != "chats" {
		return errors.New("invalid handoff owner")
	}
	_, err := tx.Exec(query, id)
	return err
}
