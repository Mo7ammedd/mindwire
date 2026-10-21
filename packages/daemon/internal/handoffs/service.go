// Package handoffs transfers reviewed context into a fresh agent session. It
// never copies a native session ID, credentials, permissions or bot instructions.
package handoffs

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/oblien/mindwire/packages/daemon/internal/agent"
	"github.com/oblien/mindwire/packages/daemon/internal/orchestrator"
	"github.com/oblien/mindwire/packages/daemon/internal/registry"
	"github.com/oblien/mindwire/packages/daemon/internal/session"
)

const MaxContextBytes = agent.MaxHandoffContextBytes

var ErrPreviewChanged = errors.New("source context changed; refresh and review the handoff before starting")

type Preview struct {
	Source        registry.HandoffOrigin `json:"source"`
	Context       string                 `json:"context"`
	Truncated     bool                   `json:"truncated"`
	HistorySource string                 `json:"historySource"` // native or recorded
	Capsule       agent.HandoffContext   `json:"capsule"`
	Digest        string                 `json:"digest"`
	Losses        []agent.HandoffLoss    `json:"losses,omitempty"`
}

type Request struct {
	NewChatID     string `json:"newChatId"`
	RequestID     string `json:"requestId"`
	TargetAgentID string `json:"targetAgentId"` // saved workspace profile, not a harness type
	Task          string `json:"task"`
	// nil builds context from the source; an explicit value is the user's reviewed edit.
	Context *string `json:"context,omitempty"`
	// Binds a reviewed context to the preview that produced it. Stale first
	// admissions must refresh; accepted retries recover their persisted receipt.
	PreviewDigest string `json:"previewDigest,omitempty"`
}

type Result struct {
	ChatID string      `json:"chatId"`
	Run    session.Run `json:"run"`
}

type Service struct {
	Registry   *registry.Store
	Store      *session.Store
	Supervisor *orchestrator.Supervisor
	Mutation   *sync.Mutex
}

func invalid(message string) error { return fmt.Errorf("%w: %s", registry.ErrInvalid, message) }

func (s *Service) Preview(ctx context.Context, sourceID string) (Preview, error) {
	s.Mutation.Lock()
	defer s.Mutation.Unlock()
	return s.preview(ctx, sourceID)
}

func (s *Service) source(ctx context.Context, id string) (*registry.Chat, *registry.Agent, *registry.Project, error) {
	if err := ctx.Err(); err != nil {
		return nil, nil, nil, err
	}
	chat, profile, project, err := s.Registry.NativeChatContext(id, s.Store)
	if err != nil {
		return nil, nil, nil, err
	}
	if chat == nil {
		return nil, nil, nil, registry.ErrNotFound
	}
	if s.Supervisor.Busy(id) {
		return nil, nil, nil, fmt.Errorf("%w: wait for the source turn to finish", registry.ErrConflict)
	}
	if err := s.Supervisor.CheckNativeChatMutation(ctx, id); err != nil {
		return nil, nil, nil, err
	}
	return chat, profile, project, nil
}

func (s *Service) preview(ctx context.Context, sourceID string) (Preview, error) {
	chat, profile, project, err := s.source(ctx, sourceID)
	if err != nil {
		return Preview{}, err
	}
	result := Preview{Source: registry.HandoffOrigin{ChatID: chat.ID, AgentID: profile.ID, Title: chat.Title}, HistorySource: "recorded"}
	if run, ok := s.Store.LatestRun(sourceID); ok {
		result.Source.RunID = run.ID
	}
	messages := s.Store.Messages(sourceID)
	var revision string
	var losses []agent.HandoffLoss
	if a, ok := s.Supervisor.Resolve(profile.AgentType); ok && a.Capabilities().History == agent.SupportNative && s.Store.Session(profile.AgentType, sourceID) != "" {
		query := agent.HistoryQuery{ChatID: sourceID, SessionID: s.Store.Session(profile.AgentType, sourceID), CWD: project.Path, Recorded: messages, Fork: s.Store.PendingFork(profile.AgentType, sourceID)}
		var native agent.HandoffHistory
		var readErr error
		if exporter, ok := a.Adapter.(agent.HandoffHistoryProvider); ok {
			native, readErr = exporter.ExportHandoff(ctx, query)
		} else {
			// Legacy adapters can positively identify non-nil history. They must
			// implement ExportHandoff to distinguish missing vs empty native state.
			native.Messages, readErr = a.Adapter.History(query)
			native.Available = native.Messages != nil
		}
		if errors.Is(readErr, agent.ErrHandoffHistoryChanged) {
			return Preview{}, ErrPreviewChanged
		}
		if readErr == nil && native.Available {
			messages, result.HistorySource, revision = native.Messages, "native", native.Revision
			losses = append(losses, native.Losses...)
		} else {
			losses = append(losses, agent.HandoffLoss{Code: "native_history_unavailable", Count: 1})
			// A pending fork refers to native history. Missing native state cannot
			// safely reconstruct its retained prefix from another conversation's log.
			if query.Fork != nil {
				return Preview{}, fmt.Errorf("%w: native fork history is unavailable", registry.ErrConflict)
			}
		}
	}
	if err := ctx.Err(); err != nil {
		return Preview{}, err
	}
	stamp, _ := json.Marshal(struct {
		Revision string
		Messages []agent.Message
		Fork     *agent.ForkPoint
	}{revision, messages, s.Store.PendingFork(profile.AgentType, sourceID)})
	sum := sha256.Sum256(stamp)
	result.Capsule = normalizeContext(agent.HandoffSource{AgentType: profile.AgentType, ChatID: sourceID, Title: chat.Title, RunID: result.Source.RunID, Revision: hex.EncodeToString(sum[:]), History: result.HistorySource, Forked: s.Store.PendingFork(profile.AgentType, sourceID) != nil}, messages, losses)
	if err := agent.ValidateHandoffContext(result.Capsule); err != nil {
		return Preview{}, invalid(err.Error())
	}
	encoded, _ := json.Marshal(result.Capsule)
	contextSum := sha256.Sum256(encoded)
	result.Digest = hex.EncodeToString(contextSum[:])
	result.Context = agent.RenderHandoffContext(result.Capsule)
	result.Losses = result.Capsule.Losses
	result.Truncated = len(result.Losses) > 0
	return result, nil
}

// Start creates a linked chat and starts an ordinary supervised turn. Persisted
// receipts plus normal turn idempotency make lost acknowledgements safe to retry.
func (s *Service) Start(ctx context.Context, sourceID string, request Request) (Result, error) {
	s.Mutation.Lock()
	defer s.Mutation.Unlock()
	request.Task = strings.TrimSpace(request.Task)
	if request.NewChatID == "" || request.NewChatID == sourceID || request.RequestID == "" || len(request.RequestID) > 128 || request.TargetAgentID == "" || request.Task == "" || len(request.Task) > 4096 || !utf8.ValidString(request.Task) {
		return Result{}, invalid("newChatId, requestId, targetAgentId and a task (up to 4096 bytes) are required")
	}
	if request.Context != nil && (len(*request.Context) > MaxContextBytes || !utf8.ValidString(*request.Context)) {
		return Result{}, invalid("context must be valid UTF-8 and at most 32768 bytes")
	}
	if request.PreviewDigest != "" {
		if value, err := hex.DecodeString(request.PreviewDigest); err != nil || len(value) != sha256.Size {
			return Result{}, invalid("previewDigest must be a SHA-256 digest")
		}
	}
	if request.Context != nil && request.PreviewDigest == "" {
		return Result{}, invalid("reviewed context requires its previewDigest")
	}
	payload, _ := json.Marshal(struct {
		Source  string
		Request Request
	}{sourceID, request})
	hash := sha256.Sum256(payload)
	digest := hex.EncodeToString(hash[:])
	receipt, err := s.Registry.Handoff(request.NewChatID)
	if err == nil {
		if receipt.Digest != digest {
			return Result{}, registry.ErrConflict
		}
	} else if !errors.Is(err, registry.ErrNotFound) {
		return Result{}, err
	} else {
		_, profile, project, err := s.source(ctx, sourceID)
		if err != nil {
			return Result{}, err
		}
		if s.Store.ChatExists(request.NewChatID) {
			return Result{}, registry.ErrConflict
		}
		snapshot, err := s.Registry.Snapshot(nil)
		if err != nil {
			return Result{}, err
		}
		var target *registry.Agent
		for i := range snapshot.Agents {
			if snapshot.Agents[i].ID == request.TargetAgentID {
				target = &snapshot.Agents[i]
				break
			}
		}
		if target == nil {
			return Result{}, invalid("target agent profile does not exist")
		}
		if target.AgentType == profile.AgentType {
			return Result{}, invalid("choose a different agent type for a cross-agent handoff")
		}
		if _, ok := s.Supervisor.Resolve(target.AgentType); !ok {
			return Result{}, invalid("target harness is unavailable")
		}
		if err := s.Registry.CheckWorkPath(project.Path); err != nil {
			return Result{}, err
		}
		preview, err := s.preview(ctx, sourceID)
		if err != nil {
			return Result{}, err
		}
		if request.PreviewDigest != "" && request.PreviewDigest != preview.Digest {
			return Result{}, ErrPreviewChanged
		}
		capsule := preview.Capsule
		if request.Context != nil && *request.Context != preview.Context {
			capsule = reviewedContext(capsule.Source, *request.Context, capsule.Losses)
		}
		destination, _ := s.Supervisor.Resolve(target.AgentType)
		var input agent.HandoffInput
		if encoder, ok := destination.Adapter.(agent.HandoffEncoder); ok {
			input, err = encoder.EncodeHandoff(capsule, request.Task)
		} else {
			input, err = agent.EncodeHandoffPrompt(capsule, request.Task, target.AgentType, "mindwire/text-v1")
		}
		if err != nil {
			return Result{}, invalid(err.Error())
		}
		contextData, _ := json.Marshal(capsule)
		contextDigest := sha256.Sum256(contextData)
		receipt = registry.HandoffReceipt{ChatID: request.NewChatID, SourceChatID: sourceID, TargetAgentID: target.ID, RequestID: request.RequestID, Digest: digest, Message: input.Message, ContextVersion: capsule.Version, ContextDigest: hex.EncodeToString(contextDigest[:]), Codec: input.Codec}
		titleRunes := []rune(request.Task)
		title := string(titleRunes[:min(80, len(titleRunes))])
		if err = s.Registry.CreateHandoff(registry.Chat{Record: registry.Record{ID: request.NewChatID}, AgentID: target.ID, ProjectID: project.ID, Title: title, HandoffFrom: &preview.Source}, receipt); err != nil {
			return Result{}, err
		}
	}
	chat, target, project, err := s.Registry.HandoffTarget(receipt.ChatID)
	if err != nil {
		return Result{}, err
	}
	if chat.AgentID != receipt.TargetAgentID {
		return Result{}, registry.ErrConflict
	}
	turnRequestID := "handoff-" + receipt.Digest
	if previous, accepted := s.Store.RunForRequest(turnRequestID); accepted {
		if previous.ChatID != chat.ID || previous.Agent != target.AgentType {
			return Result{}, registry.ErrConflict
		}
		return Result{ChatID: chat.ID, Run: previous}, nil
	}
	if _, occupied := s.Store.LatestRun(chat.ID); occupied || len(s.Store.Messages(chat.ID)) != 0 || s.Store.Session(target.AgentType, chat.ID) != "" {
		return Result{}, fmt.Errorf("%w: the prepared destination has been used for another conversation", registry.ErrConflict)
	}
	if err := s.Registry.CheckWorkPath(project.Path); err != nil {
		return Result{}, err
	}
	a, ok := s.Supervisor.Resolve(target.AgentType)
	if !ok {
		return Result{}, invalid("target harness is unavailable")
	}
	// Request options intentionally come from the target's normal configuration.
	run, err := s.Supervisor.StartTurnChecked(a, orchestrator.StartTurnInput{ChatID: chat.ID, RequestID: turnRequestID, Message: receipt.Message, CWD: project.Path})
	if err != nil {
		return Result{}, err
	}
	return Result{ChatID: chat.ID, Run: run}, nil
}
